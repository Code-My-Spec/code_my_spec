defmodule CodeMySpec.PromotionQueue.Worker do
  @moduledoc """
  One project's promotion queue, run one batch at a time.

      idle ─▶ build ─▶ gate ─┬─ green ─▶ land ─▶ idle
                             ├─ pending (analysis running) ─▶ gate again when it lands
                             └─ red ─▶ re-run a lone failure once
                                     ├▶ eject the one candidate the findings belong to
                                     └▶ bisect: gate the first half, the rest wait

  A batch is built in the project's gate copy: reset to main's HEAD, the
  candidates merged on in queue order. A candidate that conflicts is ejected at
  once — a conflict is not a gate failure, so there is nothing to bisect. The
  gate is `Promotion.gate/3`, the same clean run of every analyzer at one exact
  commit a direct promotion needs, and a green batch lands through
  `Promotion.land/6`: main is fast-forwarded to the batch commit and tagged.

  Waits on `analysis:<project>` for the gate copy's runs rather than polling,
  with a slow timer behind it in case a message is missed. Every outcome is
  told to the agent that enqueued the candidate as a `[:code_my_spec, :promotion,
  :report]` event.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.PromotionQueue.Triage
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @batch_cap 6
  @gate_label "promotion-gate"
  @recheck_ms 120_000
  @retry_ms 300_000
  @inflight_limit_ms 30 * 60_000

  @doc false
  def start_link({project_id, %Scope{} = scope}) do
    GenServer.start_link(__MODULE__, {project_id, scope}, name: via(project_id))
  end

  @doc false
  def via(project_id), do: {:via, Registry, {CodeMySpec.PromotionQueue.Registry, project_id}}

  @doc "The label the project's gate copy carries."
  def gate_label, do: @gate_label

  @impl true
  def init({project_id, scope}) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "analysis:#{project_id}")
    Repository.requeue_gating(project_id)
    send(self(), :next)

    {:ok, %{project_id: project_id, scope: scope, phase: :idle, batch: nil, timer: nil}}
  end

  @impl true
  def handle_cast({:scope, %Scope{} = scope}, state), do: {:noreply, %{state | scope: scope}}

  def handle_cast(:kick, %{phase: :idle} = state), do: next(state)
  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:next, %{phase: :idle} = state), do: next(state)
  def handle_info(:next, state), do: {:noreply, state}

  def handle_info(:gate, %{phase: :gating} = state), do: gate(state)
  def handle_info(:gate, state), do: {:noreply, state}

  def handle_info(:land, %{phase: :landing} = state), do: land(state)
  def handle_info(:land, state), do: {:noreply, state}

  # The gate copy's run finished: gate again (or, during a re-run, once the
  # re-run source itself is done).
  def handle_info({:analysis, %{status: :running}}, state), do: {:noreply, state}

  def handle_info({:analysis, %{working_copy_id: id} = run}, %{batch: %{gate: %{id: id}}} = state) do
    case state.phase do
      :gating -> gate(state)
      {:rerun, source} when source == run.source -> gate(%{state | phase: :gating})
      _ -> {:noreply, state}
    end
  end

  # Another copy's run finished while a green batch waits for in-flight runs.
  def handle_info({:analysis, _run}, %{phase: :landing} = state), do: land(state)
  def handle_info({:analysis, _run}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # -- Build ------------------------------------------------------------------

  defp next(state) do
    state = cancel_timer(state)

    case Repository.queued(state.project_id, @batch_cap) do
      [] -> {:noreply, %{state | phase: :idle, batch: nil}}
      entries -> build(state, entries)
    end
  end

  defp build(state, entries) do
    with {:ok, gate} <- gate_copy(state.scope),
         gate_scope = scope_for(state.scope, gate),
         {:ok, base} <- main_head(gate_scope, gate),
         {:ok, built} <-
           Runner.build_batch(gate_scope, gate.root, base, Enum.map(entries, & &1.commit), gate.id) do
      batch_id = Ecto.UUID.generate()
      merged = MapSet.new(built.merged)

      for %{commit: commit, files: files} <- built.conflicted,
          entry <- Enum.filter(entries, &(&1.commit == commit)),
          do: eject(state.scope, entry, conflict_reason(files))

      case Enum.filter(entries, &MapSet.member?(merged, &1.commit)) do
        [] ->
          next(state)

        in_batch ->
          in_batch = Enum.map(in_batch, &moved(&1, :gating, %{batch_id: batch_id}))

          batch = %{
            id: batch_id,
            entries: in_batch,
            gate: gate,
            scope: gate_scope,
            base: base,
            head: built.head,
            reran?: false,
            green_since: nil
          }

          Logger.info(
            "[PromotionQueue] gating #{length(in_batch)} candidate(s) at #{built.head} " <>
              "on #{base} in #{gate.root}"
          )

          send(self(), :gate)
          {:noreply, %{state | phase: :gating, batch: batch}}
      end
    else
      {:error, reason} ->
        Logger.error("[PromotionQueue] could not build a batch: #{describe(reason)}; retrying")
        {:noreply, retry_later(%{state | phase: :idle, batch: nil})}
    end
  end

  defp conflict_reason(files) do
    "it conflicts with main or with a candidate ahead of it in the queue" <>
      if(files == [], do: ".", else: ", in #{Enum.join(files, ", ")}.") <>
      " Merge main into your branch, resolve it, and promote again."
  end

  # -- Gate -------------------------------------------------------------------

  defp gate(%{batch: batch} = state) do
    state = cancel_timer(state)

    case Promotion.gate(batch.scope, batch.head) do
      {:ok, swept} -> stories_green(state, swept)
      {:pending, _} -> {:noreply, recheck_later(state)}
      {:error, reason} -> red(state, reason)
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
        send(self(), :land)
        {:noreply, %{state | phase: :landing, batch: Map.put(batch, :swept, swept)}}

      failing ->
        for {entry, reason} <- failing, do: eject(state.scope, entry, Map.get(reason, :reason))
        requeue(batch.entries -- Enum.map(failing, &elem(&1, 0)))
        next(%{state | phase: :idle, batch: nil})
    end
  end

  defp red(%{batch: batch} = state, reason) do
    problems = Promotion.blocking_problems(batch.scope)

    cond do
      problems == [] ->
        # Not a finding about the code: the gate could not run (an analyzer
        # would not start, the tree was dirty). Nothing to eject; try again.
        Logger.error("[PromotionQueue] gate could not run: #{describe(reason)}; retrying")
        requeue(batch.entries)
        {:noreply, retry_later(%{state | phase: :idle, batch: nil})}

      match?({:rerun, _}, Triage.lone_failure(problems)) and not batch.reran? ->
        {:rerun, source} = Triage.lone_failure(problems)
        Logger.info("[PromotionQueue] one #{source} finding at #{batch.head}; re-running it once")
        Analysis.start_run(batch.scope, source, [], requested_by: %{kind: "promotion"})
        {:noreply, %{state | phase: {:rerun, source}, batch: %{batch | reran?: true}}}

      true ->
        triage(state, problems)
    end
  end

  defp triage(%{batch: batch} = state, problems) do
    case attribute(batch, problems) do
      {:culprit, %Entry{} = culprit} ->
        eject(state.scope, culprit, findings(problems))
        requeue(batch.entries -- [culprit])
        next(%{state | phase: :idle, batch: nil})

      :unknown ->
        bisect(state, problems)
    end
  end

  defp attribute(%{entries: [_single]}, _problems), do: :unknown

  defp attribute(batch, problems) do
    changed =
      Map.new(batch.entries, fn entry ->
        case Runner.changed_files(batch.scope, batch.gate.root, batch.base, entry.commit, batch.gate.id) do
          {:ok, %{files: files}} -> {entry.id, files}
          _ -> {entry.id, []}
        end
      end)

    case Triage.culprit(problems, changed) do
      {:culprit, id} -> {:culprit, Enum.find(batch.entries, &(&1.id == id))}
      :unknown -> :unknown
    end
  end

  defp bisect(%{batch: %{entries: [single]}} = state, problems) do
    eject(state.scope, single, findings(problems))
    next(%{state | phase: :idle, batch: nil})
  end

  # The rest go back to waiting, still ahead of anything enqueued since; the
  # first half is rebuilt and gated on its own.
  defp bisect(%{batch: batch} = state, _problems) do
    {first, _rest} = Triage.split(batch.entries)

    Logger.info(
      "[PromotionQueue] batch at #{batch.head} is red and not attributable; " <>
        "gating the first #{length(first)} of #{length(batch.entries)}"
    )

    requeue(batch.entries)
    build(%{state | phase: :idle, batch: nil}, Enum.map(first, &Repository.get(&1.id)))
  end

  # -- Land -------------------------------------------------------------------

  # Landing restarts the app every copy's harness serves, so it waits for runs
  # in flight elsewhere — bounded, because a wedged run must not hold the queue.
  defp land(%{batch: batch} = state) do
    state = cancel_timer(state)
    batch = %{batch | green_since: batch.green_since || System.monotonic_time(:millisecond)}
    elsewhere = Analysis.running_elsewhere(batch.scope, batch.gate.id)
    waited = System.monotonic_time(:millisecond) - batch.green_since

    if elsewhere != [] and waited < @inflight_limit_ms do
      Logger.info(
        "[PromotionQueue] batch at #{batch.head} is green; waiting for runs in flight on " <>
          "#{length(elsewhere)} other copy(ies) before landing"
      )

      {:noreply, recheck_later(%{state | batch: batch}, :land)}
    else
      do_land(%{state | batch: batch})
    end
  end

  defp do_land(%{batch: batch} = state) do
    stories = Enum.map(batch.entries, &{story_of(state.scope, &1), &1.working_copy_id})
    restart = Enum.any?(batch.entries, & &1.restart)
    notify = batch.entries |> Enum.map(& &1.requested_by_agent_id) |> Enum.reject(&is_nil/1)

    case Promotion.land(batch.scope, batch.gate, batch.head, stories, Map.get(batch, :swept, []),
           restart: restart,
           notify: notify
         ) do
      {:ok, report} = result ->
        for entry <- batch.entries do
          moved(entry, :landed, %{result: %{version: report[:version], head: batch.head}})
          tell(state.scope, entry, landed_text(entry, batch, result))
        end

        next(%{state | phase: :idle, batch: nil})

      {:error, reason} ->
        # Main moved under the batch (a direct promotion landed) or the merge
        # was refused: nothing landed, so the candidates are gated again on
        # the new main.
        Logger.error("[PromotionQueue] landing #{batch.head} failed: #{describe(reason)}")
        requeue(batch.entries)
        {:noreply, retry_later(%{state | phase: :idle, batch: nil})}
    end
  end

  defp landed_text(entry, %{entries: entries}, result) do
    others = length(entries) - 1

    "Your promotion of #{subject(entry)} landed on main" <>
      if(others > 0, do: " in a batch with #{others} other candidate(s)", else: "") <>
      ". " <> Promotion.outcome_text(result)
  end

  # -- Helpers ----------------------------------------------------------------

  defp eject(scope, %Entry{} = entry, reason) do
    entry = Repository.get(entry.id) || entry
    moved(entry, :ejected, %{batch_id: nil, result: %{reason: reason}})
    Logger.info("[PromotionQueue] ejected #{subject(entry)}: #{reason}")

    tell(
      scope,
      entry,
      "Your promotion of #{subject(entry)} was taken out of the queue and nothing of it " <>
        "landed: #{reason}"
    )
  end

  defp requeue(entries) do
    for entry <- entries, %Entry{status: :gating} = fresh <- [Repository.get(entry.id)],
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

  defp findings(problems) do
    "the batch's analysis found problems in your changes:\n" <> Promotion.describe_problems(problems) <>
      "\n\nFix them and promote again."
  end

  defp subject(%Entry{story_number: nil, commit: commit}), do: String.slice(commit, 0, 12)
  defp subject(%Entry{story_number: number, commit: commit}),
    do: "story #{number} (#{String.slice(commit, 0, 12)})"

  defp story_of(_scope, %Entry{story_number: nil}), do: nil
  defp story_of(scope, %Entry{story_number: number}), do: Stories.get_story_by_number(scope, number)

  # The project's gate copy, asked for when there is none. Creating one is a
  # checkout and a harness, which sit above this queue, so it is requested as
  # an event (`Staffing` answers it) and read back.
  defp gate_copy(scope) do
    case find_gate_copy(scope) do
      %WorkingCopy{} = gate ->
        {:ok, gate}

      nil ->
        :telemetry.execute([:code_my_spec, :promotion_queue, :gate_copy_needed], %{}, %{
          scope: scope,
          label: @gate_label
        })

        case find_gate_copy(scope) do
          %WorkingCopy{} = gate -> {:ok, gate}
          nil -> {:error, %{reason: "the project has no gate copy and none could be made"}}
        end
    end
  end

  defp find_gate_copy(scope) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find(&(&1.label == @gate_label and is_binary(&1.root) and &1.root != ""))
  end

  defp main_head(gate_scope, gate) do
    case WorkingCopies.main(gate_scope) do
      %WorkingCopy{root: root} when is_binary(root) ->
        case Runner.current(gate_scope, root, gate.id) do
          {:ok, %{head: head}} when is_binary(head) -> {:ok, head}
          other -> {:error, %{reason: "could not read main's HEAD: #{inspect(other)}"}}
        end

      _ ->
        {:error, %{reason: "the project has no main working copy"}}
    end
  end

  # A scope addressing `copy`: over its harness, or — when the template is a
  # local environment (the suite) — on this machine.
  defp scope_for(%Scope{environment: %{type: :local}} = scope, copy),
    do: %{scope | active_working_copy_id: copy.id, cwd: copy.root}

  defp scope_for(%Scope{} = scope, copy), do: WorkingCopies.put_scope(scope, copy)

  defp recheck_later(state, message \\ :gate) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), message, @recheck_ms)}
  end

  defp retry_later(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :next, @retry_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp describe(%{reason: reason}) when is_binary(reason), do: reason
  defp describe(other), do: inspect(other)
end
