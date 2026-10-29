defmodule CodeMySpec.PromotionQueue.Worker do
  @moduledoc """
  One serialized promotion queue per project. The source device supplies an
  isolated gate checkout, and origin's configured development branch supplies
  the base. The main desktop and its filesystem need not be online.

  A clean exact candidate is certified, then its base, head, gate and immutable
  publication identity are persisted before publishing. A moved remote base
  rebuilds and recertifies; a lost reply replays the same publication identity
  so the remote receipt can reconcile it. Destination synchronization happens
  independently after publication. QA invalidation still blocks new publication.

  Analyzer completion events wake gating, with timers for missed events and
  temporarily disconnected source devices. Final outcomes are persisted and
  delivered to the requesting agent.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{Flakes, Run, RunsRepository}
  alias CodeMySpec.Analysis.ValidationHolds
  alias CodeMySpec.Projects
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.PromotionQueue.FlakeReports
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo.SandboxAllowance
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias Phoenix.PubSub

  # One candidate per batch: a red batch is the candidate that was in it, with
  # nothing to work out.
  @batch_cap 1
  @gate_label "promotion-gate"
  @recheck_ms 120_000
  @gate_wait_ms 15_000
  @gate_wait_limit_ms 30 * 60_000

  @doc false
  def start_link({project_id, %Scope{} = scope}), do: start_link({project_id, scope, nil})

  # `owners` are the processes whose sandbox connection this one uses under
  # test (`SandboxAllowance.owners/0`).
  def start_link({project_id, %Scope{} = scope, owners}) do
    GenServer.start_link(__MODULE__, {project_id, scope, owners}, name: via(project_id))
  end

  @doc false
  def via(project_id), do: {:via, Registry, {CodeMySpec.PromotionQueue.Registry, project_id}}

  @doc "The label the project's gate copy carries."
  def gate_label, do: @gate_label

  @doc "The shared gate label for one project on one promoting device."
  def gate_label(device_id), do: @gate_label <> ":device:" <> device_id

  def local_only?(scope),
    do:
      scope.active_project_id in Application.get_env(:code_my_spec, :local_promotion_projects, [])

  @impl true
  def init({project_id, scope, owners}) do
    SandboxAllowance.take(owners)
    PubSub.subscribe(CodeMySpec.PubSub, "analysis:#{project_id}")
    PubSub.subscribe(CodeMySpec.PubSub, "validation_holds:#{project_id}")
    PubSub.subscribe(CodeMySpec.PubSub, "completion_handoffs:#{project_id}")
    send(self(), :next)

    {:ok,
     %{
       project_id: project_id,
       scope: scope,
       phase: :idle,
       batch: nil,
       timer: nil,
       reserved_entries: [],
       # When the queue began waiting for the gate copy's runs to stop.
       gate_wait_since: nil
     }}
  end

  @impl true
  def terminate({error, stacktrace}, state) when is_list(stacktrace) do
    frame =
      Enum.find(stacktrace, fn
        {module, _, _, _} -> String.starts_with?(Atom.to_string(module), "Elixir.CodeMySpec.")
        _ -> false
      end) || List.first(stacktrace)

    # The packaged log keeps only the beginning of a crash report. Put the
    # project, phase and application frame before the exception text.
    Logger.error(
      ("[PromotionQueue] crash project=#{state.project_id} phase=#{state.phase} " <>
         "at=#{inspect(frame)} error=#{inspect(error, limit: 2, printable_limit: 100)}")
      |> String.slice(0, 450)
    )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_cast({:scope, %Scope{} = scope}, state), do: {:noreply, %{state | scope: scope}}

  # The gate copy's harness (re)joined. A batch gating there asks again: what
  # it asked before may have gone with the connection that just went.
  def handle_cast(:gate_copy_joined, %{phase: :gating, batch: batch} = state) do
    Logger.info("[PromotionQueue] the gate copy rejoined; asking the gate again at #{batch.head}")
    gate(state)
  end

  def handle_cast(:gate_copy_joined, state), do: handle_cast(:kick, state)

  def handle_cast(:kick, %{phase: :idle} = state), do: next(state)
  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:next, %{phase: :idle} = state), do: next(state)

  def handle_info(:next, state), do: {:noreply, state}

  def handle_info(:gate, %{phase: :gating, batch: batch} = state) do
    Logger.info("[PromotionQueue] gating #{batch.head}: asking the gate")
    gate(state)
  end

  def handle_info(:gate, state), do: {:noreply, state}

  def handle_info(:land, %{phase: :landing} = state), do: land(state)
  def handle_info(:land, state), do: {:noreply, state}

  # The gate copy's run finished: gate again.
  def handle_info({:analysis, %{status: :running}}, state), do: {:noreply, state}

  # Gated again only once nothing is still open on the gate copy: the gate
  # starts any source without an answer, and one dispatched but not yet begun
  # has none, so re-gating on every result would start it twice.
  def handle_info({:analysis, %{working_copy_id: id}}, %{batch: %{gate: %{id: id}}} = state) do
    if state.phase == :gating and not Analysis.running_on?(state.batch.scope),
      do: gate(state),
      else: {:noreply, state}
  end

  # A run finished while the queue waits for the gate copy to go quiet.
  def handle_info({:analysis, _run}, %{phase: :idle, gate_wait_since: since} = state)
      when not is_nil(since),
      do: next(state)

  def handle_info({:analysis, _run}, state), do: {:noreply, state}

  def handle_info({:validation_hold, %{status: :released}}, %{phase: :idle} = state),
    do: next(state)

  def handle_info({:completion_handoff, %{status: :acknowledged}}, %{phase: :idle} = state),
    do: next(state)

  def handle_info(_message, state), do: {:noreply, state}

  # -- Build ------------------------------------------------------------------

  defp next(state) do
    state = cancel_timer(state)

    if ValidationHolds.promotion_allowed?(state.project_id) do
      case Repository.gating(state.project_id) do
        [entry | _] -> recover_gating(state, entry)
        [] -> reserve_next(state)
      end
    else
      {:noreply, idle(state)}
    end
  end

  defp recover_gating(state, entry) do
    scope = %{state.scope | active_working_copy_id: entry.working_copy_id}
    saved = timing(entry)

    with head when is_binary(head) <- saved["gate_head"],
         base when is_binary(base) <- saved["gate_base"],
         gate_id when is_binary(gate_id) <- saved["gate_copy_id"],
         {:ok, %WorkingCopy{} = gate} <- WorkingCopies.fetch(gate_id),
         {:ok, ^head} <- head_of(scope, gate, "the gate copy"),
         {:ok, ^base} <- main_head(scope),
         since_string when is_binary(since_string) <- saved["gate_since"],
         {:ok, since, _} <- DateTime.from_iso8601(since_string) do
      batch = %{
        id: entry.batch_id,
        entries: [entry],
        gate: gate,
        scope: scope_for(scope, gate),
        base: base,
        head: head,
        branch: development_branch(scope),
        format: recovered_format(saved["gate_format"]),
        since: since
      }

      Logger.info("[PromotionQueue] resuming batch #{entry.batch_id} at #{head}")
      send(self(), :gate)
      {:noreply, recheck_later(%{state | scope: scope, phase: :gating, batch: batch})}
    else
      {:error, reason} ->
        Logger.warning("[PromotionQueue] cannot check gate recovery yet: #{describe(reason)}")
        {:noreply, recheck_later(idle(state), :next)}

      _ ->
        Logger.warning("[PromotionQueue] gate changed; rebuilding candidate #{entry.id}")
        {:ok, _} = Repository.move(entry, :queued, %{batch_id: nil})
        reserve_next(state)
    end
  end

  defp recovered_format(%{"commit" => commit, "files" => files}),
    do: %{commit: commit, files: files}

  defp recovered_format(_), do: nil

  defp reserve_next(state) do
    with [entry] <- Repository.queued(state.project_id, @batch_cap) do
      scope = %{state.scope | active_working_copy_id: entry.working_copy_id}
      state = %{state | scope: scope}

      case entry.result do
        %{"publication" => publication} ->
          recover_publication(state, entry, publication)

        _ ->
          case ready(scope) do
            {:ok, base} ->
              reserve_and_build(state, entry, base)

            {:error, reason} ->
              Logger.warning("[PromotionQueue] source unavailable: #{describe(reason)}")
              {:noreply, recheck_later(idle(state), :next)}
          end
      end
    else
      [] ->
        {:noreply, idle(state)}
    end
  end

  # Origin is fetched on the source device; its isolated gate must be reachable.
  # Destination availability is independent of admission and publication.
  defp ready(scope) do
    with {:ok, base} <- main_head(scope),
         {:ok, gate} <- gate_copy(scope),
         {:ok, _head} <- head_of(scope, gate, "the gate copy") do
      {:ok, base}
    end
  end

  defp reserve_and_build(state, entry, base) do
    case Repository.move(entry, :gating, %{result: start_timing(entry)}) do
      {:ok, reserved} ->
        build_on(%{state | reserved_entries: [reserved]}, [reserved], base)

      {:error, :validation_held} ->
        {:noreply, idle(state)}

      {:error, :completion_handoff_pending} ->
        {:noreply, idle(state)}

      {:error, reason} ->
        Logger.error("[PromotionQueue] could not take #{subject(entry)}: #{describe(reason)}")
        {:noreply, idle(state)}
    end
  end

  defp idle(state), do: %{state | phase: :idle, batch: nil, reserved_entries: []}

  defp build_on(state, entries, base) do
    case if(local_only?(state.scope), do: on_main(state.scope, entries, base), else: []) do
      [] -> build(state, entries, base, level_with_main(state.scope, entries, base))
      on_main -> already_on_main(state, on_main, base)
    end
  end

  # Candidates main already contains land the moment they are picked: they have
  # nothing to gate, and in a batch they could be ejected over another
  # candidate's findings. Asked in the gate copy, which shares the repository;
  # if it cannot answer, the build handles them.
  defp on_main(scope, entries, base) do
    with %WorkingCopy{} = gate <- find_gate_copy(scope),
         {:ok, %{contained: [_ | _] = contained}} <-
           Runner.contained(
             WorkingCopies.execution_context(scope_for(scope, gate)),
             gate.root,
             base,
             Enum.map(entries, & &1.commit),
             gate.id
           ) do
      Enum.filter(entries, &(&1.commit in contained))
    else
      _ -> []
    end
  end

  defp build(state, entries, base, {:ok, copy}),
    do: gating(state, entries, copy, base, hd(entries).commit, nil)

  defp build(state, entries, base, :no), do: build_in_gate_copy(state, entries, base)

  # A lone candidate that already contains main is its own batch commit, so a
  # certification its own copy already holds at that commit — every analyzer
  # answered there, nothing blocking — is the gate's answer, and no second sweep
  # of the same tree is needed.
  #
  # Only reused, never run: runs started in the requester's copy are exposed
  # to whoever keeps editing it. Anything still to run goes to the gate copy.
  # A promote that asked for fresh runs is not answered by its copy's old ones.
  defp level_with_main(_scope, [%{fresh: true}], _base), do: :no

  defp level_with_main(scope, [entry], base) do
    with {:ok, %WorkingCopy{root: root} = copy} when is_binary(root) <-
           WorkingCopies.fetch(entry.working_copy_id),
         own = scope_for(scope, copy),
         {:ok, %{head: head}} <-
           Runner.precheck(WorkingCopies.execution_context(own), root, copy.id, base),
         true <- head == entry.commit,
         true <- Promotion.certified_at?(own, entry.commit),
         # Read-only: a requester's copy is not ours to commit in. Unformatted,
         # it goes through the gate copy, which formats it.
         {:ok, %{unformatted: []}} <-
           Runner.format(WorkingCopies.execution_context(own), root, copy.id, check: true) do
      {:ok, copy}
    else
      _ -> :no
    end
  end

  defp level_with_main(_scope, _entries, _base), do: :no

  defp build_in_gate_copy(state, entries, base) do
    with {:ok, gate} <- gate_copy(state.scope),
         gate_scope = scope_for(state.scope, gate),
         :ok <- gate_quiet(gate_scope, gate_wait_since(state)),
         environment = WorkingCopies.execution_context(gate_scope),
         {:ok, built} <-
           Runner.build_batch(
             environment,
             gate.root,
             base,
             Enum.map(entries, & &1.commit),
             gate.id
           ),
         # Each candidate's analyzers start on databases its own migrations
         # build, not an ejected predecessor's schema.
         {:ok, _} <- Runner.reset_test_databases(environment, gate.root, gate.id) do
      merged = MapSet.new(built.merged)
      conflicted = MapSet.new(built.conflicted, & &1.commit)

      for %{commit: commit, files: files} <- built.conflicted,
          entry <- Enum.filter(entries, &(&1.commit == commit)),
          do: eject(state.scope, entry, conflict_reason(commit, base, files))

      case Enum.split_with(entries, &MapSet.member?(merged, &1.commit)) do
        {[], unaccounted} ->
          next_or_unaccounted(state, unaccounted, conflicted, built)

        {in_batch, _out} ->
          format_then_gate(state, in_batch, {gate, environment}, base, built.head)
      end
    else
      {:error, :gate_busy} -> wait_for_gate(state)
      {:error, %{unreachable: true} = reason} -> wait_for_gate_harness(state, entries, reason)
      {:error, reason} -> could_not_gate(state, entries, reason)
    end
  end

  # The batch is formatted in the gate copy and the result committed on top of
  # it as its own commit, so the gate certifies, and main receives, a formatted
  # tree. The format commit is named in what the agent is told. A batch already
  # on main (`head == base`) has nothing to format.
  defp format_then_gate(state, entries, {gate, environment}, base, head) do
    case Runner.format(environment, gate.root, gate.id) do
      {:ok, %{commit: nil}} ->
        gating(state, entries, gate, base, head, nil)

      {:ok, %{commit: commit, formatted: files, head: formatted_head}} ->
        gating(state, entries, gate, base, formatted_head, %{commit: commit, files: files})

      {:error, %{unreachable: true} = reason} ->
        wait_for_gate_harness(state, entries, reason)

      {:error, reason} ->
        could_not_gate(state, entries, reason)
    end
  end

  # One the build neither merged nor ejected is still queued, so
  # building again at once rebuilds the same batch, silently, forever.
  defp next_or_unaccounted(state, unaccounted, conflicted, built) do
    case Enum.reject(unaccounted, &MapSet.member?(conflicted, &1.commit)) do
      [] -> next(%{state | reserved_entries: []})
      left -> could_not_gate(state, left, %{reason: unaccounted_reason(left, built)})
    end
  end

  # The gate copy's harness restarts after every landing that changes harness
  # code, and a batch built in that second found no machine and ejected a sound
  # candidate (d759ce130, 2026-10-15). Waited out like a busy gate -- the copy
  # rejoining wakes it -- and bounded the same way, so a harness that never
  # comes back still lets the queue move.
  defp wait_for_gate_harness(state, entries, reason) do
    if waited_out?(gate_wait_since(state)),
      do: could_not_gate(state, entries, reason),
      else: wait_for_gate(state)
  end

  # The tree and test databases are not swapped under a run still going in the
  # gate copy (it hangs to its timeout). Asked to stop again in case the first
  # request was lost, then waited for — bounded, since a run row nothing will
  # ever close would otherwise hold the queue forever.
  defp gate_quiet(gate_scope, waiting_since) do
    cond do
      not Analysis.running_on?(gate_scope) ->
        :ok

      waited_out?(waiting_since) ->
        Logger.error(
          "[PromotionQueue] the gate copy's runs did not stop in " <>
            "#{div(@gate_wait_limit_ms, 60_000)} minutes; building over them"
        )

        :ok

      true ->
        Analysis.cancel_on(gate_scope, "the gate copy is needed for the next batch")
        {:error, :gate_busy}
    end
  end

  # Read rather than matched: a code reload can hand this code a state from
  # before the field existed.
  defp gate_wait_since(state), do: Map.get(state, :gate_wait_since)

  defp waited_out?(nil), do: false

  defp waited_out?(since),
    do: System.monotonic_time(:millisecond) - since > @gate_wait_limit_ms

  defp wait_for_gate(state) do
    requeue(state.reserved_entries)
    Logger.info("[PromotionQueue] waiting for the gate copy's runs to stop before building")

    state =
      %{state | phase: :idle, batch: nil, reserved_entries: []}
      |> Map.put(:gate_wait_since, gate_wait_since(state) || System.monotonic_time(:millisecond))
      |> cancel_timer()

    {:noreply, %{state | timer: Process.send_after(self(), :next, @gate_wait_ms)}}
  end

  # A batch that leaves the gate copy, for any reason, leaves no runs there. A
  # batch on a candidate's own copy started none, and that copy's runs are its
  # agent's.
  defp release_gate(%{batch: %{gate: %WorkingCopy{label: "promotion-gate" <> _}} = batch}) do
    Analysis.cancel_on(batch.scope, "the batch at #{batch.head} left the gate")
    :ok
  end

  defp release_gate(_state), do: :ok

  # `gate` is the copy the batch commit is checked out in and certified on:
  # the gate copy, or a lone level candidate's own copy.
  # A batch whose commit is main's HEAD adds nothing and is not gated: main's
  # own findings there are no finding against any candidate. Each lands as it is.
  defp gating(state, entries, gate, base, head, format) do
    if base == head and local_only?(state.scope) do
      already_on_main(state, entries, base)
    else
      begin_gating(state, entries, gate, base, head, format)
    end
  end

  defp begin_gating(state, entries, gate, base, head, format) do
    batch_id = Ecto.UUID.generate()

    in_batch =
      Enum.map(entries, fn entry ->
        entry = finish_stage(entry, "gate-build", "build_started_at")

        timing =
          timing(entry)
          |> Map.put("gate_copy_id", gate.id)
          |> Map.put("gate_base", base)
          |> Map.put("gate_head", head)
          |> Map.put("gate_since", DateTime.to_iso8601(DateTime.utc_now()))
          |> Map.put("gate_format", format)

        moved(entry, :gating, %{batch_id: batch_id, result: put_timing(entry, timing)})
      end)

    batch = %{
      id: batch_id,
      entries: in_batch,
      gate: gate,
      scope: scope_for(state.scope, gate),
      base: base,
      head: head,
      branch: development_branch(state.scope),
      # The commit the promotion's own `mix format` added, or nil.
      format: format,
      # When gating began: a run that failed before it could say which commit
      # it started on counts against this batch only if it is this batch's.
      since: DateTime.add(DateTime.utc_now(), -1, :second)
    }

    environment = WorkingCopies.execution_context(batch.scope)

    case Runner.select_tests(environment, gate.root, base, head, gate.id) do
      {:ok, selection} ->
        selection = Map.new(selection, fn {key, value} -> {to_string(key), value} end)

        in_batch =
          Enum.map(in_batch, fn entry ->
            result = Map.put(entry.result || %{}, "test_selection", selection)
            moved(entry, :gating, %{result: result})
          end)

        batch = %{batch | entries: in_batch}

        Logger.info(
          "[PromotionQueue] gating #{length(in_batch)} candidate(s) at #{head} on #{base} in #{gate.root}"
        )

        # Asked now, and again on the recheck timer whatever happens to this one:
        # a lost `:gate` must not stall the queue.
        send(self(), :gate)

        {:noreply,
         %{state | phase: :gating, batch: batch, reserved_entries: []}
         |> Map.put(:gate_wait_since, nil)
         |> recheck_later()}

      {:error, reason} ->
        could_not_gate(%{state | batch: batch}, in_batch, reason)
    end
  end

  # Taken, and stopped short of a verdict. Ejected rather than requeued: a
  # requeued candidate heads the queue again and fails the same way, forever.
  defp could_not_gate(state, entries, reason) do
    release_gate(state)

    Enum.each(
      entries,
      &eject(state.scope, &1, "the queue could not gate it: #{describe(reason)}")
    )

    next(idle(state))
  end

  defp unaccounted_reason(entries, built) do
    "the batch build neither merged nor refused " <>
      Enum.map_join(entries, ", ", &String.slice(&1.commit, 0, 12)) <>
      ": #{inspect(Map.take(built, [:merged, :conflicted]))}"
  end

  # 41644862: the gate compiled this candidate's own conflict markers and
  # reported "could not reset the gate's test database" -- the database
  # error was real, but the candidate and the commit it conflicted with were
  # never said, so nothing pointed at what to actually do. Names both.
  defp conflict_reason(commit, base, files) do
    "#{String.slice(commit, 0, 12)} conflicts merging onto the development branch (#{String.slice(base, 0, 12)}) " <>
      "or a candidate ahead of it in the queue" <>
      if(files == [], do: ".", else: ", in #{Enum.join(files, ", ")}.") <>
      " Merge the current development branch into your branch, resolve it, and promote again."
  end

  # -- Gate -------------------------------------------------------------------

  defp gate(%{batch: batch} = state) do
    state = cancel_timer(state)

    if Map.has_key?(batch, :flake_reruns) do
      finish_flake_reruns(state)
    else
      case failed_runs(batch) do
        [] -> gate_runs(state)
        failed -> could_not_run(state, failed)
      end
    end
  end

  defp gate_runs(%{batch: batch} = state) do
    case Promotion.gate(batch.scope, batch.head,
           fresh_since: fresh_since(batch.entries),
           retry_failed_since: queued_since(batch.entries)
         ) do
      {:ok, swept} ->
        state = %{state | batch: record_runs(batch, swept)}
        state |> note_reused(swept) |> assets_build(swept)

      {:pending, _pending} ->
        {:noreply, recheck_later(state)}

      {:error, reason} ->
        red(state, reason)
    end
  end

  defp queued_since(entries),
    do: entries |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime, fn -> nil end)

  # The earliest a fresh entry in the batch was queued: runs before it answer
  # for none of them. `nil` when no entry asked.
  defp fresh_since(entries) do
    entries
    |> Enum.filter(&(&1.fresh == true))
    |> Enum.map(& &1.inserted_at)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # No analyzer runs the asset pipeline, so assets are built here once the
  # ledger is green, rather than as a new `Run.sources()` member every
  # Problem/Run/UI surface would have to learn.
  defp assets_build(%{batch: batch} = state, swept) do
    environment = WorkingCopies.execution_context(batch.scope)

    started = DateTime.utc_now()
    result = Runner.build_assets(environment, batch.gate.root, batch.gate.id)
    state = %{state | batch: record_stage(batch, "asset-build", started)}

    case result do
      {:ok, _} -> stories_green(state, swept)
      {:error, reason} -> eject_batch(state, reason.reason)
    end
  end

  # A failed run can mean the candidate prevents the analyzer from starting.
  # A collision with the gate runner's own key socket says nothing about the
  # candidate, so let the ordinary gate path ask for a fresh ExUnit run.
  defp failed_runs(batch) do
    Enum.filter(Run.sources(), fn source ->
      batch.scope
      |> RunsRepository.failed_runs_at_commit(source, batch.head, batch.since)
      |> Enum.any?(&(not retryable_socket_failure?(&1)))
    end)
  end

  defp retryable_socket_failure?(%Run{source: "exunit", stats: %{"error" => reason}})
       when is_binary(reason) do
    String.contains?(reason, ":test_suite_did_not_run") and
      String.contains?(reason, ":sops_key_socket_address_in_use")
  end

  defp retryable_socket_failure?(_), do: false

  defp could_not_run(%{batch: batch} = state, sources) do
    why = Enum.map_join(sources, "\n\n", &cannot_run(batch.scope, &1))
    Logger.error("[PromotionQueue] #{Enum.join(sources, ", ")} failed at #{batch.head}.\n#{why}")

    eject_batch(
      state,
      "#{Enum.join(sources, ", ")} could not run at the batch commit #{batch.head}.\n\n#{why}"
    )
  end

  defp cannot_run(scope, source) do
    case Analysis.latest_run(scope, source) do
      %{output: output} when is_binary(output) and output != "" ->
        "#{source}: …#{String.slice(output, -800, 800)}"

      _ ->
        "#{source}: its runs fail with no output"
    end
  end

  # The certifying run must also show each story's own spex green, as a direct
  # promotion requires before it latches a story.
  defp stories_green(%{batch: batch} = state, swept) do
    failing =
      for entry <- batch.entries,
          story = story_of(state.scope, entry),
          files_scope = %{state.scope | active_working_copy_id: entry.working_copy_id},
          {:error, reason} <- [Promotion.story_spex_check(batch.scope, story, files_scope)],
          do: {entry, reason}

    case failing do
      [] ->
        batch = Map.put(batch, :swept, swept)
        batch = persist_publication(state.scope, batch)
        send(self(), :land)
        {:noreply, %{state | phase: :landing, batch: batch}}

      failing ->
        release_gate(state)
        for {entry, reason} <- failing, do: eject(state.scope, entry, Map.get(reason, :reason))
        requeue(batch.entries -- Enum.map(failing, &elem(&1, 0)))
        next(idle(state))
    end
  end

  defp red(%{batch: batch} = state, reason) do
    problems = Promotion.blocking_problems_at(batch.scope, batch.head)

    cond do
      problems == [] ->
        could_not_gate(state, batch.entries, reason)

      rerunnable_test_failures?(batch, problems) ->
        start_flake_reruns(state, problems)

      true ->
        log_flake_classifications(batch)
        eject_batch(state, findings(problems))
    end
  end

  defp rerunnable_test_failures?(batch, problems) do
    sources = problems |> Enum.map(& &1.source) |> Enum.uniq()

    length(gate_answers(batch)) == length(Run.sources()) and
      Enum.all?(problems, &(&1.source_type == :test and &1.source in ~w(exunit spex))) and
      Enum.all?(sources, fn source ->
        case Analysis.answer_at_commit(batch.scope, source, batch.head) do
          %Run{kind: :full, findings: %{"failures" => [_ | _]}} -> true
          _ -> false
        end
      end)
  end

  defp start_flake_reruns(%{batch: batch} = state, problems) do
    sources = problems |> Enum.map(& &1.source) |> Enum.uniq()

    result =
      Enum.reduce_while(sources, %{}, fn source, reruns ->
        with {:ok, targets} <- failed_test_targets(batch, source),
             {:ok, :started, run_id} <-
               Analysis.start_run(batch.scope, source, targets,
                 requested_by: %{kind: "promotion_flake_rerun"}
               ) do
          {:cont, Map.put(reruns, source, {run_id, targets})}
        else
          other -> {:halt, {:error, {source, other}}}
        end
      end)

    case result do
      {:error, {source, failure}} ->
        eject_batch(
          state,
          "the " <> source <> " failed-test rerun could not start: " <> inspect(failure)
        )

      reruns ->
        batch = batch |> Map.put(:flake_reruns, reruns) |> Map.put(:flake_problems, problems)
        {:noreply, recheck_later(%{state | batch: batch})}
    end
  end

  defp failed_test_targets(batch, source) do
    case Analysis.answer_at_commit(batch.scope, source, batch.head) do
      %Run{kind: :full, findings: %{"failures" => [_ | _] = failures}} ->
        suffix = if source == "spex", do: "_spex.exs", else: "_test.exs"

        if Enum.all?(failures, fn failure ->
             file = failure["file"]
             line = failure["line"]

             is_binary(file) and String.starts_with?(file, "test/") and
               String.ends_with?(file, suffix) and Path.type(file) == :relative and
               ".." not in Path.split(file) and is_integer(line) and line > 0
           end) do
          targets =
            failures |> Enum.map(&"#{&1["file"]}:#{&1["line"]}") |> Enum.uniq() |> Enum.sort()

          {:ok, targets}
        else
          {:error, :unusable_failure_location}
        end

      _ ->
        {:error, :missing_full_gate_failures}
    end
  end

  defp finish_flake_reruns(%{batch: batch} = state) do
    runs =
      for {source, {run_id, targets}} <- batch.flake_reruns, into: %{} do
        {source, {RunsRepository.get_run_in_project(batch.scope, run_id), targets}}
      end

    cond do
      Enum.any?(runs, fn {_source, {run, _targets}} -> match?(%Run{status: :running}, run) end) ->
        {:noreply, recheck_later(state)}

      Enum.all?(runs, fn {source, {run, targets}} ->
        flake_rerun_passed?(batch, source, run, targets)
      end) ->
        for {source, {run, _targets}} <- runs,
            %Run{findings: %{"failures" => failures}} <-
              [Analysis.answer_at_commit(batch.scope, source, batch.head)],
            failure <- failures do
          Logger.info(
            "[PromotionQueue] " <>
              to_string(failure["file"]) <>
              ": " <>
              to_string(failure["name"]) <> " — confirmed flake; rerun=" <> to_string(run.id)
          )
        end

        swept = gate_answers(batch)
        state = %{state | batch: record_runs(batch, swept)}
        assets_build(state, swept)

      true ->
        log_flake_classifications(batch)
        eject_batch(state, findings(batch.flake_problems))
    end
  end

  defp flake_rerun_passed?(batch, source, %Run{} = run, targets) do
    run.working_copy_id == batch.gate.id and run.source == source and
      run.kind == :partial and get_in(run.args || %{}, ["args"]) == targets and
      Run.at_commit?(run, batch.head) and run.exit_status == 0 and
      Map.get(run.findings || %{}, "failures", []) == [] and
      rerun_executed_tests?(source, run)
  end

  defp flake_rerun_passed?(_batch, _source, _run, _targets), do: false

  defp confirmed_flakes(batch) do
    for source <- ~w(exunit spex),
        %Run{findings: %{} = findings} = gate_run <-
          [Analysis.answer_at_commit(batch.scope, source, batch.head)],
        failure <- Map.get(findings, "failures", []),
        is_binary(failure["file"]) and is_binary(failure["name"]),
        %Run{} = rerun <- [passing_flake_rerun(batch, failure)] do
      %{
        source: source,
        file: failure["file"],
        name: failure["name"],
        message: to_string(failure["message"]),
        gate_run_id: gate_run.id,
        rerun_id: rerun.id,
        commit: batch.head
      }
    end
  end

  defp passing_flake_rerun(batch, failure) do
    source = if String.starts_with?(failure["file"], "test/spex/"), do: "spex", else: "exunit"

    case Map.get(Map.get(batch, :flake_reruns, %{}), source) do
      {run_id, targets} ->
        run = RunsRepository.get_run_in_project(batch.scope, run_id)

        if match?(%Run{status: :completed}, run) and
             run.working_copy_id == batch.gate.id and run.source == source and
             run.kind == :partial and get_in(run.args || %{}, ["args"]) == targets and
             Run.at_commit?(run, batch.head) and is_map(run.findings) and
             rerun_executed_tests?(source, run) and
             not Enum.any?(Map.get(run.findings, "failures", []), fn rerun_failure ->
               rerun_failure["file"] == failure["file"] and
                 rerun_failure["name"] == failure["name"]
             end) do
          run
        end

      _ ->
        nil
    end
  end

  defp rerun_executed_tests?("exunit", run) do
    is_integer((run.stats || %{})["tests"]) and (run.stats || %{})["tests"] > 0
  end

  defp rerun_executed_tests?("spex", run) do
    case Regex.run(~r/\b(\d+) tests?, \d+ failures?\b/, run.output || "") do
      [_, count] -> String.to_integer(count) > 0
      _ -> false
    end
  end

  defp log_flake_classifications(batch) do
    unrelated? = fn run, failure -> unrelated_candidate?(batch, run, failure) end

    for %{source: source, result: result} <-
          Flakes.classify_gate_failures(batch.scope, batch.gate.id, batch.head,
            unrelated_candidate?: unrelated?
          ) do
      failure = result.failure

      case passing_flake_rerun(batch, failure) do
        %Run{} = rerun ->
          Logger.info(
            "[PromotionQueue] #{source} #{failure["file"]}: #{failure["name"]} — confirmed flake; rerun=#{rerun.id}; evidence=#{rerun.id}"
          )

        nil ->
          evidence = Enum.map_join(result.evidence, ",", &"#{&1.run_id}:#{&1.working_copy_id}")
          label = if result.classification == :suspected_flake, do: "suspect", else: "not a flake"

          Logger.info(
            "[PromotionQueue] #{source} #{failure["file"]}: #{failure["name"]} — #{label}; evidence=#{evidence}"
          )
      end
    end
  rescue
    error ->
      Logger.warning(
        "[PromotionQueue] flake classification unavailable: #{Exception.message(error)}"
      )
  end

  defp unrelated_candidate?(batch, run, failure) do
    file = failure["file"]

    covered =
      file |> String.replace_prefix("test/", "lib/") |> String.replace_suffix("_test.exs", ".ex")

    environment = WorkingCopies.execution_context(batch.scope)

    if run.working_copy_id in [batch.gate.id | Enum.map(batch.entries, & &1.working_copy_id)] do
      false
    else
      case Runner.changed(environment, batch.gate.root, batch.base, run.commit, batch.gate.id) do
        {:ok, %{paths: paths}} when is_list(paths) ->
          file not in paths and covered not in paths

        _ ->
          false
      end
    end
  end

  # A red batch is its one candidate's.
  defp eject_batch(%{batch: batch} = state, reason) do
    batch = record_runs(batch, gate_answers(batch))
    release_gate(state)
    Enum.each(batch.entries, &eject(state.scope, &1, reason <> format_note(batch)))
    next(idle(state))
  end

  defp format_note(%{format: %{commit: commit, files: files}}),
    do:
      "\n\nThe promotion ran mix format before gating and committed it as #{commit} " <>
        "(#{length(files)} file(s): #{Enum.join(files, ", ")}). Look there first and carry on " <>
        "from it."

  defp format_note(_batch), do: ""

  defp already_on_main(state, entries, head) do
    Logger.info(
      "[PromotionQueue] #{length(entries)} candidate(s) already on main at #{head}; " <>
        "landing them without a gate"
    )

    stories =
      for entry <- entries,
          story = story_of(state.scope, entry),
          do: {story, entry.working_copy_id, entry.commit}

    case Promotion.record_landed_stories(state.scope, stories, main_version(state.scope), head) do
      :ok ->
        already_landed(state, entries, head)

      {:error, %{landed: true} = reason} ->
        hold_landed(state, entries, head, reason)

      {:error, reason} ->
        Enum.each(entries, &eject(state.scope, &1, reason.reason))
        next(%{state | phase: :idle, batch: nil})
    end
  end

  defp already_landed(state, entries, head) do
    for entry <- entries do
      landed =
        moved(entry, :landed, %{
          batch_id: nil,
          result: %{"head" => head, "already_on_main" => true}
        })

      issue_landed(state.scope, landed, head)

      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        Repository.topic(state.project_id),
        {:promotion_queue_landed, entry.id, {:ok, %{queue_outcome: landed}}}
      )

      tell(
        state.scope,
        entry,
        "Your promotion of #{subject(entry)} has landed on main already " <>
          "(#{String.slice(head, 0, 12)}): there was nothing to gate or land."
      )
    end

    next(idle(state))
  end

  # -- Land -------------------------------------------------------------------

  # A green batch lands at once, without waiting for runs on other copies: a
  # landing restarts the harness only when its own code moved (`after-promote`).
  defp land(state) do
    if local_only?(state.scope), do: on_current_main(state, &do_land/1), else: do_land(state)
  end

  # The batch was certified on `base`. If main moved on while it gated —
  # anything committed to main another way — it cannot land as certified: it
  # is rebuilt on the new main and gated again at once. Not a failure of the
  # candidates, so none is ejected.
  defp on_current_main(%{batch: batch} = state, then) do
    case main_head(state.scope) do
      {:ok, head} when head == batch.base ->
        then.(state)

      {:ok, moved} ->
        Logger.info(
          "[PromotionQueue] main moved from #{batch.base} to #{moved} while #{batch.head} " <>
            "gated; rebuilding the batch on it"
        )

        requeue(batch.entries)
        next(idle(state))

      {:error, _} ->
        then.(state)
    end
  end

  defp do_land(%{batch: batch} = state) do
    stories = Enum.map(batch.entries, &{story_of(state.scope, &1), &1.working_copy_id, &1.commit})
    restart = Enum.any?(batch.entries, & &1.restart)
    notify = batch.entries |> Enum.map(& &1.requested_by_agent_id) |> Enum.reject(&is_nil/1)

    landing = if local_only?(state.scope), do: :land, else: :land_remote
    landing_started = DateTime.utc_now()

    case apply(Promotion, landing, [
           batch.scope,
           batch.gate,
           batch.head,
           stories,
           Map.get(batch, :swept, []),
           [
             restart: restart,
             notify: notify,
             base: batch.base,
             branch: Map.get(batch, :branch, development_branch(state.scope)),
             promotion_id: batch.id,
             publication_sequence: Map.get(batch, :publication_sequence, 0)
           ]
         ]) do
      {:ok, report} = result ->
        batch = record_stage(batch, "landing", landing_started)

        for entry <- batch.entries do
          moved(entry, :landed, %{result: landed_result(entry, batch, report)})
          issue_landed(state.scope, entry, batch.head)
          FlakeReports.record_landed(state.scope, entry, confirmed_flakes(batch))

          # The landing report itself, in memory, for a caller waiting on this
          # entry (`PromotionQueue.await/2`): it answers with what a direct
          # promotion would have. Sent after the entry is recorded landed.
          Phoenix.PubSub.broadcast(
            CodeMySpec.PubSub,
            Repository.topic(state.project_id),
            {:promotion_queue_landed, entry.id, result}
          )

          tell_landed(state.scope, entry, landed_text(entry, batch, result))
        end

        next(idle(state))

      {:error, %{published: true} = reason} ->
        hold_landed(state, batch.entries, batch.head, Map.put(reason, :landed, true))

      {:error, %{retryable: true}} ->
        {:noreply, recheck_later(state, :land)}

      {:error, %{base_moved: true}} ->
        for entry <- batch.entries, do: moved(entry, :queued, %{batch_id: nil, result: %{}})
        next(idle(state))

      {:error, %{landed: true} = reason} ->
        hold_landed(state, batch.entries, batch.head, reason)

      # Only its team can fix this (its QA is not at its commit). Ejected, not
      # requeued: requeued it would head the queue and block everything behind.
      {:error, %{qa_not_current: true} = reason} ->
        Enum.each(batch.entries, &eject(state.scope, &1, reason.reason))
        next(idle(state))

      # `root` is stuck on our own merge commit with no rollback: main moved
      # because of this attempt, not independently. Asking `on_current_main`
      # would see exactly that commit, read it as a landing to rebuild on, and
      # gate it again -- which finds the candidate's commit already an
      # ancestor of main and lands it `already_on_main`, without ever
      # fetching the submodule or deploying. Eject at once instead.
      {:error, %{stuck_on_main: true} = reason} ->
        Logger.error("[PromotionQueue] landing #{batch.head} failed: #{describe(reason)}")
        could_not_gate(state, batch.entries, %{reason: "landing failed: #{describe(reason)}"})

      {:error, reason} ->
        # Main moved under the batch (a direct promotion landed) or the merge
        # was refused: nothing landed, so the candidates are gated again on
        # the new main.
        # Main moving in the moment between the check above and the merge is
        # the same race, and rebuilds at once; anything else is ejected.
        fail = fn state ->
          Logger.error("[PromotionQueue] landing #{batch.head} failed: #{describe(reason)}")
          could_not_gate(state, batch.entries, %{reason: "landing failed: #{describe(reason)}"})
        end

        if local_only?(state.scope), do: on_current_main(state, fail), else: fail.(state)
    end
  end

  defp hold_landed(state, entries, head, reason) do
    for entry <- entries do
      moved(entry, :landed, %{
        batch_id: nil,
        result:
          Map.merge(Repository.get(entry.id).result || %{}, %{
            "head" => head,
            "assignment_held" => true,
            "reason" => reason.reason
          })
      })

      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        Repository.topic(state.project_id),
        {:promotion_queue_landed, entry.id, {:error, reason}}
      )

      tell(state.scope, entry, Promotion.outcome_text({:error, reason}))
    end

    next(%{state | phase: :idle, batch: nil})
  end

  defp landed_result(entry, batch, report) do
    base = %{
      "timing" => timing(entry),
      "test_selection" => Map.get(entry.result || %{}, "test_selection"),
      "version" => report[:version],
      "head" => batch.head,
      "promotion_id" => batch.id,
      "base" => batch.base,
      "branch" => Map.get(batch, :branch),
      "published" => report[:published]
    }

    case batch.format do
      %{commit: commit, files: files} ->
        Map.merge(base, %{"format_commit" => commit, "formatted" => files})

      _ ->
        base
    end
  end

  defp landed_text(entry, %{entries: entries} = batch, result) do
    others = length(entries) - 1

    destination =
      if match?({:ok, %{published: true}}, result),
        do: "published to origin/#{Map.get(batch, :branch, "main")}",
        else: "landed on main"

    "Your promotion of #{subject(entry)} #{destination}" <>
      if(others > 0, do: " in a batch with #{others} other candidate(s)", else: "") <>
      ". " <>
      Promotion.outcome_text(result) <>
      landed_format_note(batch) <>
      reused_note(batch)
  end

  # Certified on runs that finished before any entry in the batch was queued:
  # the commit had not moved, but something outside it (a path dependency) may
  # have, and the caller should know to ask for fresh runs (issue c9d61407).
  defp note_reused(%{batch: batch} = state, swept) do
    queued = batch.entries |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime, fn -> nil end)

    reused =
      Enum.filter(swept, fn %{finished_at: finished} ->
        queued && finished && DateTime.compare(finished, queued) == :lt
      end)

    %{state | batch: Map.put(batch, :reused, reused)}
  end

  defp reused_note(%{reused: [_ | _] = reused}) do
    runs =
      Enum.map_join(reused, ", ", fn %{source: source, finished_at: at} ->
        "#{source} (finished #{Calendar.strftime(at, "%H:%M:%SZ")})"
      end)

    " Certified on runs recorded at this commit before you promoted: #{runs}. If anything " <>
      "outside the commit changed since (a path dependency such as client_utils), promote " <>
      "again with fresh: true."
  end

  defp reused_note(_batch), do: ""

  defp landed_format_note(%{format: %{commit: commit, files: files}}),
    do:
      " The promotion also ran mix format and committed #{length(files)} file(s) as " <>
        "#{commit}: #{Enum.join(files, ", ")}. Your copy is behind the published candidate by that commit."

  defp landed_format_note(_batch), do: ""

  # -- Helpers ----------------------------------------------------------------

  defp timing(entry), do: get_in(entry.result || %{}, ["timing"]) || %{}

  defp put_timing(entry, value), do: Map.put(entry.result || %{}, "timing", value)

  defp start_timing(entry) do
    now = DateTime.utc_now()
    stages = %{"queue-wait" => max(DateTime.diff(now, entry.inserted_at, :second), 0)}
    put_timing(entry, %{"stages" => stages, "build_started_at" => DateTime.to_iso8601(now)})
  end

  defp finish_stage(entry, stage, start_key) do
    case get_in(timing(entry), [start_key]) do
      started when is_binary(started) ->
        {:ok, at, _} = DateTime.from_iso8601(started)

        stages =
          Map.put(
            timing(entry)["stages"] || %{},
            stage,
            max(DateTime.diff(DateTime.utc_now(), at, :second), 0)
          )

        value = timing(entry) |> Map.put("stages", stages) |> Map.delete(start_key)
        moved(entry, entry.status, %{result: put_timing(entry, value)})

      _ ->
        entry
    end
  end

  defp record_stage(batch, stage, started) do
    seconds = max(DateTime.diff(DateTime.utc_now(), started, :second), 0)

    entries =
      Enum.map(batch.entries, fn entry ->
        stages = Map.put(timing(entry)["stages"] || %{}, stage, seconds)

        moved(entry, entry.status, %{
          result: put_timing(entry, Map.put(timing(entry), "stages", stages))
        })
      end)

    %{batch | entries: entries}
  end

  defp record_runs(batch, swept) do
    ids = Enum.map(swept, & &1.run_id) |> Enum.reject(&is_nil/1)

    failures =
      for source <- ~w(exunit spex),
          %Run{kind: :full, findings: findings} <-
            [Analysis.answer_at_commit(batch.scope, source, batch.head)],
          failure <- Map.get(findings || %{}, "failures", []),
          is_binary(failure["file"]) and is_binary(failure["name"]),
          do: failure

    entries =
      Enum.map(batch.entries, fn entry ->
        value = Map.put(timing(entry), "run_ids", ids)
        result = put_timing(entry, value)

        result =
          case result["test_selection"] do
            %{} = selection ->
              selected = selection["selected_tests"] || []
              changed = selection["changed_files"] || []

              misses =
                for failure <- failures,
                    failure["file"] not in selected and
                      is_nil(passing_flake_rerun(batch, failure)),
                    do: %{
                      "file" => failure["file"],
                      "name" => failure["name"],
                      "changed_files" => changed
                    }

              flakes =
                for failure <- failures,
                    passing_flake_rerun(batch, failure),
                    do: failure["file"]

              selection =
                selection
                |> Map.put("failed_tests", failures |> Enum.map(& &1["file"]) |> Enum.uniq())
                |> Map.put("misses", Enum.uniq(misses))
                |> Map.put("flakes", Enum.uniq(flakes))

              Map.put(result, "test_selection", selection)

            _ ->
              result
          end

        moved(entry, entry.status, %{result: result})
      end)

    %{batch | entries: entries}
  end

  defp gate_answers(batch) do
    for source <- Run.sources(),
        %Run{kind: :full} = run <- [Analysis.answer_at_commit(batch.scope, source, batch.head)] do
      %{
        source: source,
        run_id: run.id,
        finished_at: run.finished_at,
        commit: run.completed_commit
      }
    end
  end

  defp eject(scope, %Entry{} = entry, reason) do
    entry = Repository.get(entry.id) || entry

    moved(entry, :ejected, %{
      batch_id: nil,
      result: Map.put(entry.result || %{}, "reason", reason)
    })

    Logger.info("[PromotionQueue] ejected #{subject(entry)}: #{reason}")

    tell_durably(
      scope,
      entry,
      "Your promotion of #{subject(entry)} was taken out of the queue and nothing of it " <>
        "landed: #{reason}"
    )
  end

  defp requeue(entries) do
    for entry <- entries,
        %Entry{status: :gating} = fresh <- [Repository.get(entry.id)],
        do: moved(fresh, :queued, %{batch_id: nil})

    :ok
  end

  defp moved(entry, status, attrs) do
    {:ok, entry} = Repository.move(entry, status, attrs)
    entry
  end

  # Nobody enqueued it from a conversation (an operator, a Claude Code session):
  # the log is the record, and `await/2` answers a caller that waits.
  defp tell(_scope, %Entry{requested_by_agent_id: nil}, text),
    do: Logger.info("[PromotionQueue] #{text}")

  defp tell(scope, %Entry{requested_by_agent_id: agent_id}, text) do
    :telemetry.execute([:code_my_spec, :promotion, :report], %{}, %{
      scope: scope,
      agent_id: agent_id,
      text: text,
      what: "promotion queue outcome"
    })
  end

  # 1d65a84e: the landed outcome is the one message an agent's open
  # promote_issue/story_promoted task depends on to ever close -- tagged
  # distinctly from the shared "promotion queue outcome" `what` so
  # Agents.Events can route it through a durable admission instead of the
  # fire-and-forget dispatch every other promotion-report text still uses.
  # PromotionQueue may not call Agents directly (Boundary), so this stays a
  # telemetry event like the rest of `tell/2`, only with its own `what`.
  defp tell_landed(scope, entry, text), do: tell_durably(scope, entry, text, "promotion landed")

  # An ejection is the other outcome an agent waits on: until it hears, it holds
  # its promote task open. Sent fire-and-forget, it was dropped whenever the
  # agent was not running -- at 15:11 on 2026-10-15 the same harness restart
  # that ejected 71d28513's fix also swallowed the notice, and the coder waited
  # 90 minutes on a result that had already come.
  defp tell_durably(scope, entry, text, what \\ "promotion ejected")

  defp tell_durably(_scope, %Entry{requested_by_agent_id: nil}, text, _what),
    do: Logger.info("[PromotionQueue] #{text}")

  defp tell_durably(scope, %Entry{requested_by_agent_id: agent_id}, text, what) do
    :telemetry.execute([:code_my_spec, :promotion, :report], %{}, %{
      scope: scope,
      agent_id: agent_id,
      text: text,
      what: what
    })
  end

  defp findings(problems) do
    "the batch's analysis found problems in your changes:\n" <>
      Promotion.describe_problems(problems) <>
      "\n\nFix them and promote again."
  end

  defp subject(%Entry{} = entry), do: Entry.describe(entry)

  defp story_of(scope, %Entry{} = entry) do
    case Entry.story_number(entry) do
      nil -> nil
      number -> Stories.get_story_by_number(scope, number)
    end
  end

  # An issue's fix on main resolves the issue once its QA has passed.
  defp issue_landed(scope, %Entry{} = entry, head) do
    with id when is_binary(id) <- Entry.issue_id(entry),
         {:error, reason} <- Qa.issue_fix_landed(scope, id, head) do
      Logger.error("[PromotionQueue] issue #{id}'s fix landed at #{head}: #{inspect(reason)}")
    end

    :ok
  end

  # The project's gate copy, asked for when there is none. Creating one is a
  # checkout and a harness, which sit above this queue, so it is requested as
  # an event (`Staffing` answers it) and read back.
  defp gate_copy(scope) do
    with {:ok, label} <- gate_label_for(scope),
         {:ok, gate} <- find_or_make_gate(scope, label) do
      retire_legacy_gates(scope, gate)
      {:ok, gate}
    end
  end

  defp find_or_make_gate(scope, label) do
    case find_gate_copy(scope, label) do
      %WorkingCopy{} = gate ->
        {:ok, gate}

      nil ->
        case legacy_gate_copy(scope) do
          %WorkingCopy{} = legacy -> WorkingCopies.relabel(scope, legacy, label)
          nil -> make_gate_copy(scope, label)
        end
    end
  end

  defp make_gate_copy(scope, label) do
    :telemetry.execute([:code_my_spec, :promotion_queue, :gate_copy_needed], %{}, %{
      scope: scope,
      label: label,
      source_copy_id: if(local_only?(scope), do: nil, else: scope.active_working_copy_id)
    })

    case find_gate_copy(scope, label) do
      %WorkingCopy{} = gate -> {:ok, gate}
      nil -> {:error, %{reason: "the project has no gate copy and none could be made"}}
    end
  end

  defp find_gate_copy(scope) do
    with {:ok, label} <- gate_label_for(scope), do: find_gate_copy(scope, label)
  end

  defp find_gate_copy(scope, label) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find(&(gate_on_source?(scope, &1) and &1.label == label and gate_root?(&1)))
  end

  defp legacy_gate_copy(scope) do
    if local_only?(scope) do
      nil
    else
      scope
      |> WorkingCopies.list_harnesses()
      |> Enum.find(
        &(gate_on_source?(scope, &1) and legacy_gate_label?(&1.label) and gate_root?(&1))
      )
    end
  end

  # A gate whose checkout its harness reports gone is no gate: kept, its record
  # stood in for the copy and every batch was refused on its unreadable HEAD
  # (03:00Z, a disk cleanup removed the folders and left the records). Passed
  # over, it is asked for again, and `Staffing` retires the gone record.
  defp gate_root?(%WorkingCopy{root: root} = gate),
    do: is_binary(root) and root != "" and is_nil(gate.path_missing_since)

  defp legacy_gate_label?("promotion-gate:" <> suffix),
    do: not String.starts_with?(suffix, "device:")

  defp legacy_gate_label?(_), do: false

  defp retire_legacy_gates(scope, gate) do
    unless local_only?(scope) do
      scope
      |> WorkingCopies.list_harnesses()
      |> Enum.filter(
        &(&1.id != gate.id and gate_on_source?(scope, &1) and
            legacy_gate_label?(&1.label) and gate_root?(&1))
      )
      |> Enum.each(fn obsolete ->
        obsolete_scope = scope_for(scope, obsolete)

        unless Analysis.running_on?(obsolete_scope) or
                 Repository.publication_gate_in_use?(scope.active_project_id, obsolete.id) do
          :telemetry.execute([:code_my_spec, :promotion_queue, :gate_copy_obsolete], %{}, %{
            scope: scope,
            gate: obsolete,
            source_copy_id: scope.active_working_copy_id
          })
        end
      end)
    end
  end

  # The gate is a worktree of the source checkout, so it must run on that device
  # to reach Git, dependencies and the build/test environment. The server or
  # another device cannot assume access to that disk. One gate per device lets
  # every source copy there reuse it without crossing this boundary.
  defp gate_on_source?(scope, gate) do
    if local_only?(scope) do
      true
    else
      case WorkingCopies.fetch(scope.active_working_copy_id) do
        {:ok, source} -> not is_nil(source.device_id) and source.device_id == gate.device_id
        _ -> false
      end
    end
  end

  defp main_version(scope) do
    if local_only?(scope), do: local_main_version(scope), else: nil
  end

  defp local_main_version(scope) do
    with %WorkingCopy{root: root} = main when is_binary(root) <- WorkingCopies.main(scope),
         {:ok, %{version: version}} <-
           Runner.current(WorkingCopies.execution_context(scope_for(scope, main)), root, main.id) do
      version
    else
      _ -> nil
    end
  end

  # Main's HEAD, read through main's own copy.
  defp main_head(scope) do
    if local_only?(scope) do
      local_main_head(scope)
    else
      with {:ok, source} <- WorkingCopies.fetch(scope.active_working_copy_id),
           {:ok, %{head: head}} <-
             Runner.remote_head(
               WorkingCopies.execution_context(scope_for(scope, source)),
               source.root,
               development_branch(scope),
               source.id
             ) do
        {:ok, head}
      end
    end
  end

  defp local_main_head(scope) do
    case WorkingCopies.main(scope) do
      %WorkingCopy{root: root} = main when is_binary(root) -> head_of(scope, main, "main")
      _ -> {:error, %{reason: "the project has no main working copy"}}
    end
  end

  defp gate_label_for(scope) do
    if local_only?(scope) do
      {:ok, @gate_label}
    else
      case WorkingCopies.fetch(scope.active_working_copy_id) do
        {:ok, %WorkingCopy{device_id: id}} when is_binary(id) -> {:ok, gate_label(id)}
        _ -> {:error, %{reason: "the source copy has no device for a promotion gate"}}
      end
    end
  end

  defp development_branch(scope) do
    case Projects.get_project(scope, scope.active_project_id) do
      {:ok, project} -> Map.get(project, :development_branch) || "main"
      _ -> "main"
    end
  end

  # Persist before the first side effect against origin. A restarted worker
  # replays publication with the same receipt identity, never rebuilds it.
  defp persist_publication(scope, batch) do
    if local_only?(scope) do
      batch
    else
      {:ok, sequence} = CodeMySpec.Promotion.DeviceSync.reserve_sequence(scope)

      publication = %{
        "id" => batch.id,
        "base" => batch.base,
        "head" => batch.head,
        "gate_id" => batch.gate.id,
        "branch" => batch.branch,
        "sequence" => sequence
      }

      for entry <- batch.entries,
          do:
            moved(entry, :gating, %{
              result: Map.put(entry.result || %{}, "publication", publication)
            })

      Map.put(batch, :publication_sequence, sequence)
    end
  end

  defp recover_publication(state, entry, publication) do
    case WorkingCopies.fetch(publication["gate_id"]) do
      {:ok, gate} ->
        batch = %{
          id: publication["id"],
          base: publication["base"],
          head: publication["head"],
          branch: publication["branch"],
          publication_sequence: publication["sequence"] || 0,
          gate: gate,
          entries: [entry],
          scope: scope_for(state.scope, gate),
          swept: [],
          format: nil
        }

        land(%{state | phase: :landing, batch: batch})

      {:error, _} ->
        {:noreply, recheck_later(idle(state), :next)}
    end
  end

  defp head_of(scope, %WorkingCopy{} = copy, name) do
    case Runner.current(
           WorkingCopies.execution_context(scope_for(scope, copy)),
           copy.root,
           copy.id
         ) do
      {:ok, %{head: head}} when is_binary(head) -> {:ok, head}
      other -> {:error, %{reason: "could not read #{name}'s HEAD: #{inspect(other)}"}}
    end
  end

  # Database calls keep their project scope. Disk operations resolve the
  # environment from this exact copy id; Scope carries identity, not runtime.
  defp scope_for(%Scope{} = scope, copy),
    do: %{scope | active_working_copy_id: copy.id, cwd: copy.root}

  defp recheck_later(state, message \\ :gate) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), message, @recheck_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp describe(%{reason: reason}) when is_binary(reason), do: reason
  defp describe(other), do: inspect(other)
end
