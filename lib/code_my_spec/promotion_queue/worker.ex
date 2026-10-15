defmodule CodeMySpec.PromotionQueue.Worker do
  @moduledoc """
  One project's promotion queue, run one batch at a time.

      idle ─▶ build ─▶ gate ─┬─ green ─▶ land ─▶ idle
                             ├─ pending (analysis running) ─▶ gate again when it lands
                             └─ red ─▶ the candidate is ejected

  A batch is built in the project's gate copy: reset to main's HEAD, the
  candidates merged on in queue order. A candidate that conflicts is ejected at
  once, told as a conflict rather than a gate failure. The
  gate is `Promotion.gate/3`, the same clean run of every analyzer at one exact
  commit a direct promotion needs, and a green batch lands through
  `Promotion.land/6`: main is fast-forwarded to the batch commit and tagged.

  Nothing is retried. A candidate is taken only once main and the gate copy
  can both be read; until then it stays queued and a copy joining wakes the
  queue. Once taken, anything that stops it landing ejects it with the reason,
  so one candidate cannot hold the queue by failing the same way forever. Only
  main moving under a batch rebuilds it, since that is no failure of its own.

  Waits on `analysis:<project>` for the gate copy's runs rather than polling,
  with a slow timer behind it in case a message is missed. Every outcome is
  told to the agent that enqueued the candidate as a `[:code_my_spec, :promotion,
  :report]` event.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.ValidationHolds
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.PromotionQueue.Entry
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

  @impl true
  def init({project_id, scope, owners}) do
    SandboxAllowance.take(owners)
    PubSub.subscribe(CodeMySpec.PubSub, "analysis:#{project_id}")
    PubSub.subscribe(CodeMySpec.PubSub, "validation_holds:#{project_id}")
    PubSub.subscribe(CodeMySpec.PubSub, "completion_handoffs:#{project_id}")
    Repository.requeue_gating(project_id)
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
      reserve_next(state)
    else
      {:noreply, idle(state)}
    end
  end

  defp reserve_next(state) do
    with [entry] <- Repository.queued(state.project_id, @batch_cap),
         {:ok, base} <- ready(state.scope) do
      reserve_and_build(state, entry, base)
    else
      [] ->
        {:noreply, idle(state)}

      {:error, reason} ->
        Logger.warning(
          "[PromotionQueue] not taking a candidate: #{describe(reason)}. " <>
            "It stays queued until a copy joins."
        )

        {:noreply, idle(state)}
    end
  end

  # What has to be reachable before a candidate is taken: main, to build on and
  # land, and the gate copy's checkout. A failure here is nobody's candidate.
  defp ready(scope) do
    with {:ok, base} <- main_head(scope),
         {:ok, gate} <- gate_copy(scope),
         {:ok, _head} <- head_of(scope, gate, "the gate copy") do
      {:ok, base}
    end
  end

  defp reserve_and_build(state, entry, base) do
    case Repository.move(entry, :gating, %{}) do
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
    case on_main(state.scope, entries, base) do
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
             WorkingCopies.environment(scope_for(scope, gate)),
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
    do: gating(state, entries, copy, base, hd(entries).commit)

  defp build(state, entries, base, :no), do: build_in_gate_copy(state, entries, base)

  # A lone candidate that already contains main is its own batch commit, so a
  # certification its own copy already holds at that commit — every analyzer
  # answered there, nothing blocking — is the gate's answer, and no second sweep
  # of the same tree is needed.
  #
  # Only reused, never run: runs started in the requester's copy are exposed
  # to whoever keeps editing it. Anything still to run goes to the gate copy.
  defp level_with_main(scope, [entry], base) do
    with {:ok, %WorkingCopy{root: root} = copy} when is_binary(root) <-
           WorkingCopies.fetch(entry.working_copy_id),
         own = scope_for(scope, copy),
         {:ok, %{head: head}} <-
           Runner.precheck(WorkingCopies.environment(own), root, copy.id, base),
         true <- head == entry.commit,
         true <- Promotion.certified_at?(own, entry.commit) do
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
         environment = WorkingCopies.environment(gate_scope),
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
          do: eject(state.scope, entry, conflict_reason(files))

      case Enum.split_with(entries, &MapSet.member?(merged, &1.commit)) do
        {[], unaccounted} ->
          # One the build neither merged nor ejected is still queued, so
          # building again at once rebuilds the same batch, silently, forever.
          case Enum.reject(unaccounted, &MapSet.member?(conflicted, &1.commit)) do
            [] -> next(%{state | reserved_entries: []})
            left -> could_not_gate(state, left, %{reason: unaccounted_reason(left, built)})
          end

        {in_batch, _out} ->
          gating(state, in_batch, gate, base, built.head)
      end
    else
      {:error, :gate_busy} -> wait_for_gate(state)
      {:error, reason} -> could_not_gate(state, entries, reason)
    end
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
  defp release_gate(%{batch: %{gate: %WorkingCopy{label: @gate_label}} = batch}) do
    Analysis.cancel_on(batch.scope, "the batch at #{batch.head} left the gate")
    :ok
  end

  defp release_gate(_state), do: :ok

  # `gate` is the copy the batch commit is checked out in and certified on:
  # the gate copy, or a lone level candidate's own copy.
  # A batch whose commit is main's HEAD adds nothing and is not gated: main's
  # own findings there are no finding against any candidate. Each lands as it is.
  defp gating(state, entries, _gate, base, base), do: already_on_main(state, entries, base)

  defp gating(state, entries, gate, base, head) do
    batch_id = Ecto.UUID.generate()
    in_batch = Enum.map(entries, &moved(&1, :gating, %{batch_id: batch_id}))

    batch = %{
      id: batch_id,
      entries: in_batch,
      gate: gate,
      scope: scope_for(state.scope, gate),
      base: base,
      head: head,
      # When gating began: a run that failed before it could say which commit
      # it started on counts against this batch only if it is this batch's.
      since: DateTime.add(DateTime.utc_now(), -1, :second)
    }

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

  defp conflict_reason(files) do
    "it conflicts with main or with a candidate ahead of it in the queue" <>
      if(files == [], do: ".", else: ", in #{Enum.join(files, ", ")}.") <>
      " Merge main into your branch, resolve it, and promote again."
  end

  # -- Gate -------------------------------------------------------------------

  defp gate(%{batch: batch} = state) do
    state = cancel_timer(state)

    case failed_runs(batch) do
      [] -> gate_runs(state)
      failed -> could_not_run(state, failed)
    end
  end

  defp gate_runs(%{batch: batch} = state) do
    case Promotion.gate(batch.scope, batch.head) do
      {:ok, swept} -> assets_build(state, swept)
      {:pending, _pending} -> {:noreply, recheck_later(state)}
      {:error, reason} -> red(state, reason)
    end
  end

  # No analyzer runs the asset pipeline, so assets are built here once the
  # ledger is green, rather than as a new `Run.sources()` member every
  # Problem/Run/UI surface would have to learn.
  defp assets_build(%{batch: batch} = state, swept) do
    environment = WorkingCopies.environment(batch.scope)

    case Runner.build_assets(environment, batch.gate.root, batch.gate.id) do
      {:ok, _} -> stories_green(state, swept)
      {:error, reason} -> eject_batch(state, reason.reason)
    end
  end

  # A run that failed at the batch commit is red like a finding: the batch's own
  # change may be what stops the analyzer running (a broken mix.exs, a config
  # the suite cannot boot with), and a failure at main too is main's to fix.
  # Not retried. Runs orphaned by a harness going away are not failures here.
  defp failed_runs(batch),
    do:
      Enum.filter(
        Run.sources(),
        &(Analysis.failed_at_commit(batch.scope, &1, batch.head, batch.since) > 0)
      )

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
        send(self(), :land)
        {:noreply, %{state | phase: :landing, batch: Map.put(batch, :swept, swept)}}

      failing ->
        release_gate(state)
        for {entry, reason} <- failing, do: eject(state.scope, entry, Map.get(reason, :reason))
        requeue(batch.entries -- Enum.map(failing, &elem(&1, 0)))
        next(idle(state))
    end
  end

  defp red(%{batch: batch} = state, reason) do
    problems = Promotion.blocking_problems_at(batch.scope, batch.head)

    if problems == [] do
      # No finding about the code: the gate could not run (an analyzer would
      # not start, the tree was dirty).
      could_not_gate(state, batch.entries, reason)
    else
      eject_batch(state, findings(problems))
    end
  end

  # A red batch is its one candidate's.
  defp eject_batch(%{batch: batch} = state, reason) do
    release_gate(state)
    Enum.each(batch.entries, &eject(state.scope, &1, reason))
    next(idle(state))
  end

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
        "Your promotion of #{subject(entry)} is already on main " <>
          "(#{String.slice(head, 0, 12)}): there was nothing to gate or land."
      )
    end

    next(idle(state))
  end

  # -- Land -------------------------------------------------------------------

  # A green batch lands at once, without waiting for runs on other copies: a
  # landing restarts the harness only when its own code moved (`after-promote`).
  defp land(state), do: on_current_main(state, &do_land/1)

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

    case Promotion.land(batch.scope, batch.gate, batch.head, stories, Map.get(batch, :swept, []),
           restart: restart,
           notify: notify
         ) do
      {:ok, report} = result ->
        for entry <- batch.entries do
          moved(entry, :landed, %{result: %{"version" => report[:version], "head" => batch.head}})
          issue_landed(state.scope, entry, batch.head)

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

      {:error, %{landed: true} = reason} ->
        hold_landed(state, batch.entries, batch.head, reason)

      # Only its team can fix this (its QA is not at its commit). Ejected, not
      # requeued: requeued it would head the queue and block everything behind.
      {:error, %{qa_not_current: true} = reason} ->
        Enum.each(batch.entries, &eject(state.scope, &1, reason.reason))
        next(idle(state))

      {:error, reason} ->
        # Main moved under the batch (a direct promotion landed) or the merge
        # was refused: nothing landed, so the candidates are gated again on
        # the new main.
        # Main moving in the moment between the check above and the merge is
        # the same race, and rebuilds at once; anything else is ejected.
        on_current_main(state, fn state ->
          Logger.error("[PromotionQueue] landing #{batch.head} failed: #{describe(reason)}")
          could_not_gate(state, batch.entries, %{reason: "landing failed: #{describe(reason)}"})
        end)
    end
  end

  defp hold_landed(state, entries, head, reason) do
    for entry <- entries do
      moved(entry, :landed, %{
        batch_id: nil,
        result: %{
          "head" => head,
          "assignment_held" => true,
          "reason" => reason.reason
        }
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

  defp landed_text(entry, %{entries: entries}, result) do
    others = length(entries) - 1

    "Your promotion of #{subject(entry)} landed on main" <>
      if(others > 0, do: " in a batch with #{others} other candidate(s)", else: "") <>
      ". " <> Promotion.outcome_text(result)
  end

  # -- Helpers ----------------------------------------------------------------

  defp eject(scope, %Entry{} = entry, reason) do
    entry = Repository.get(entry.id) || entry
    moved(entry, :ejected, %{batch_id: nil, result: %{"reason" => reason}})
    Logger.info("[PromotionQueue] ejected #{subject(entry)}: #{reason}")

    tell(
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
  defp tell_landed(_scope, %Entry{requested_by_agent_id: nil}, text),
    do: Logger.info("[PromotionQueue] #{text}")

  defp tell_landed(scope, %Entry{requested_by_agent_id: agent_id}, text) do
    :telemetry.execute([:code_my_spec, :promotion, :report], %{}, %{
      scope: scope,
      agent_id: agent_id,
      text: text,
      what: "promotion landed"
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

  defp main_version(scope) do
    with %WorkingCopy{root: root} = main when is_binary(root) <- WorkingCopies.main(scope),
         {:ok, %{version: version}} <-
           Runner.current(WorkingCopies.environment(scope_for(scope, main)), root, main.id) do
      version
    else
      _ -> nil
    end
  end

  # Main's HEAD, read through main's own copy.
  defp main_head(scope) do
    case WorkingCopies.main(scope) do
      %WorkingCopy{root: root} = main when is_binary(root) -> head_of(scope, main, "main")
      _ -> {:error, %{reason: "the project has no main working copy"}}
    end
  end

  defp head_of(scope, %WorkingCopy{} = copy, name) do
    case Runner.current(WorkingCopies.environment(scope_for(scope, copy)), copy.root, copy.id) do
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
