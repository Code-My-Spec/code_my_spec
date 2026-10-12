defmodule CodeMySpec.PromotionQueue.Worker do
  @moduledoc """
  One project's promotion queue, run one batch at a time.

      idle ─▶ build ─▶ gate ─┬─ green ─▶ land ─▶ idle
                             ├─ pending (analysis running) ─▶ gate again when it lands
                             └─ red ─▶ bisect: a batch of one is ejected; otherwise
                                        gate the first half, the rest wait

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
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.ValidationHolds
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.Qa
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias Phoenix.PubSub

  # One candidate per batch (John, 2026-10-05): a red batch is the candidate
  # that was in it, with nothing to work out.
  # Still to do: with a cap of 1, `bisect/2`'s split branch is unreachable; remove it.
  @batch_cap 1
  @gate_label "promotion-gate"
  @recheck_ms 120_000
  @gate_wait_ms 15_000
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

  # Another copy's run finished while a green batch waits for in-flight runs.
  def handle_info({:analysis, _run}, %{phase: :landing} = state), do: land(state)

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
    case Repository.queued(state.project_id, @batch_cap) do
      [] ->
        {:noreply, idle(state)}

      [entry] ->
        reserve_and_build(state, entry)
    end
  end

  defp reserve_and_build(state, entry) do
    case Repository.move(entry, :gating, %{}) do
      {:ok, reserved} -> build(%{state | reserved_entries: [reserved]}, [reserved])
      {:error, :validation_held} -> {:noreply, idle(state)}
      {:error, :completion_handoff_pending} -> {:noreply, idle(state)}
      {:error, reason} -> could_not_build(state, reason)
    end
  end

  defp idle(state), do: %{state | phase: :idle, batch: nil, reserved_entries: []}

  defp build(state, entries) do
    case main_head(state.scope) do
      {:ok, base} -> build_on(state, entries, base)
      {:error, reason} -> could_not_build(state, reason)
    end
  end

  defp build_on(state, entries, base) do
    case on_main(state.scope, entries, base) do
      [] -> build(state, entries, base, level_with_main(state.scope, entries, base))
      on_main -> already_on_main(state, on_main, base)
    end
  end

  # Candidates main already contains land the moment they are picked: they have
  # nothing to gate, and batched with others they would ride a gate as no-ops
  # and could be ejected over another candidate's findings (966ee65a, three
  # entries, 2026-10-05). Asked in the gate copy, which shares the repository;
  # one that cannot answer leaves them to the build, which handles them as
  # before.
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
  # Only reused, never run: a gate that starts runs in the requester's copy is
  # exposed to whoever keeps editing it (Harness, 2026-10-05 — an in-app coder
  # works on after it promotes). Anything still to run goes to the gate copy.
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
         :ok <- gate_quiet(gate_scope, state.gate_wait_since),
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
         # build: an ejected one left its schema there for the next (2026-10-11).
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
            left -> could_not_build(state, %{reason: unaccounted_reason(left, built)})
          end

        {in_batch, _out} ->
          gating(state, in_batch, gate, base, built.head)
      end
    else
      {:error, :gate_busy} -> wait_for_gate(state)
      {:error, reason} -> could_not_build(state, reason)
    end
  end

  # The tree and test databases are not swapped under a run still going in the
  # gate copy: the last batch's exunit hung its full thirty minutes when the
  # next batch reset them underneath it (2026-10-12). Asked to stop again in
  # case the first request was lost, then waited for.
  #
  # Bounded like the wait on other copies' runs: a row nothing will ever close
  # (its harness went and no sweep came) would otherwise hold the queue forever.
  defp gate_quiet(gate_scope, waiting_since) do
    cond do
      not Analysis.running_on?(gate_scope) ->
        :ok

      waited_out?(waiting_since) ->
        Logger.error(
          "[PromotionQueue] the gate copy's runs did not stop in " <>
            "#{div(@inflight_limit_ms, 60_000)} minutes; building over them"
        )

        :ok

      true ->
        Analysis.cancel_on(gate_scope, "the gate copy is needed for the next batch")
        {:error, :gate_busy}
    end
  end

  defp waited_out?(nil), do: false

  defp waited_out?(since),
    do: System.monotonic_time(:millisecond) - since > @inflight_limit_ms

  defp wait_for_gate(state) do
    requeue(state.reserved_entries)
    Logger.info("[PromotionQueue] waiting for the gate copy's runs to stop before building")

    state =
      cancel_timer(%{
        state
        | phase: :idle,
          batch: nil,
          reserved_entries: [],
          gate_wait_since: state.gate_wait_since || System.monotonic_time(:millisecond)
      })

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
  # A batch whose commit is main's HEAD adds nothing: every candidate in it is
  # already on main — landed before, or contained in what has landed since. It
  # is not gated: whatever main's own analysis finds there is no finding against
  # any of them, and blaming one for it sent an agent to "fix" work that had
  # already landed (the queue's first live night, 2026-10-05). Each lands as it
  # is, with what a landing does for its story or issue.
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
      green_since: nil,
      # When gating began: a run that failed before it could say which commit
      # it started on counts against this batch only if it is this batch's.
      since: DateTime.add(DateTime.utc_now(), -1, :second)
    }

    Logger.info(
      "[PromotionQueue] gating #{length(in_batch)} candidate(s) at #{head} on #{base} in #{gate.root}"
    )

    # Asked now, and again on the recheck timer whatever happens to this one:
    # a batch built at 08:41:43 on 2026-10-05 never gated — its `:gate` went
    # unanswered, nothing else was due to ask, and the queue sat for over an
    # hour behind it.
    send(self(), :gate)

    {:noreply,
     recheck_later(%{
       state
       | phase: :gating,
         batch: batch,
         reserved_entries: [],
         gate_wait_since: nil
     })}
  end

  defp could_not_build(state, reason) do
    requeue(state.reserved_entries)
    Logger.error("[PromotionQueue] could not build a batch: #{describe(reason)}; retrying")
    {:noreply, retry_later(%{state | phase: :idle, batch: nil, reserved_entries: []})}
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
      {:ok, swept} -> stories_green(state, swept)
      {:pending, _pending} -> {:noreply, recheck_later(state)}
      {:error, reason} -> red(state, reason)
    end
  end

  # A run that failed at the batch commit is red like a finding: the batch's own
  # change may be what stops the analyzer running (a broken mix.exs, a config
  # the suite cannot boot with), and a failure at main too is main's to fix.
  # Not retried. Runs a harness going away orphaned are not failures here
  # (3c59be47): every landing restarts the harness.
  defp failed_runs(batch),
    do:
      Enum.filter(
        Run.sources(),
        &(Analysis.failed_at_commit(batch.scope, &1, batch.head, batch.since) > 0)
      )

  defp could_not_run(%{batch: batch} = state, sources) do
    why = Enum.map_join(sources, "\n\n", &cannot_run(batch.scope, &1))
    Logger.error("[PromotionQueue] #{Enum.join(sources, ", ")} failed at #{batch.head}.\n#{why}")

    bisect(
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
      # Not a finding about the code: the gate could not run (an analyzer
      # would not start, the tree was dirty). Nothing to eject; try again.
      Logger.error("[PromotionQueue] gate could not run: #{describe(reason)}; retrying")
      release_gate(state)
      requeue(batch.entries)
      {:noreply, retry_later(%{state | phase: :idle, batch: nil})}
    else
      bisect(state, findings(problems))
    end
  end

  # Whose change is red: a batch of one is ejected with `reason`; a larger one
  # is split until it is.
  defp bisect(%{batch: %{entries: [single]}} = state, reason) do
    release_gate(state)
    eject(state.scope, single, reason)
    next(idle(state))
  end

  # The rest go back to waiting, still ahead of anything enqueued since; the
  # first half is rebuilt and gated on its own.
  defp bisect(%{batch: batch} = state, _reason) do
    {first, _rest} = Enum.split(batch.entries, div(length(batch.entries) + 1, 2))

    Logger.info(
      "[PromotionQueue] batch at #{batch.head} is red; " <>
        "gating the first #{length(first)} of #{length(batch.entries)}"
    )

    release_gate(state)
    requeue(batch.entries)
    build(%{state | phase: :idle, batch: nil}, Enum.map(first, &Repository.get(&1.id)))
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
      on_current_main(%{state | batch: batch}, &do_land/1)
    end
  end

  # The batch was certified on `base`. If main moved on while it gated —
  # anything committed to main another way — it cannot land as certified: it
  # is rebuilt on the new main and gated again, now rather than after a retry
  # period. Not a failure of the candidates, so none is ejected.
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

          tell(state.scope, entry, landed_text(entry, batch, result))
        end

        next(idle(state))

      {:error, %{landed: true} = reason} ->
        hold_landed(state, batch.entries, batch.head, reason)

      # Only its team can fix this — the QA it needs is not at its commit — so
      # retrying it changes nothing. Re-queued, it went back to the head of the
      # queue and was refused again every cycle, holding every candidate behind
      # it (2026-10-11).
      {:error, %{qa_not_current: true} = reason} ->
        Enum.each(batch.entries, &eject(state.scope, &1, reason.reason))
        next(idle(state))

      {:error, reason} ->
        # Main moved under the batch (a direct promotion landed) or the merge
        # was refused: nothing landed, so the candidates are gated again on
        # the new main.
        # Main moving in the moment between the check above and the merge is
        # the same race, and rebuilds at once; anything else waits to retry.
        on_current_main(state, fn state ->
          Logger.error("[PromotionQueue] landing #{batch.head} failed: #{describe(reason)}")
          requeue(batch.entries)
          {:noreply, retry_later(%{state | phase: :idle, batch: nil})}
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
      %WorkingCopy{root: root} = main when is_binary(root) ->
        case Runner.current(WorkingCopies.environment(scope_for(scope, main)), root, main.id) do
          {:ok, %{head: head}} when is_binary(head) -> {:ok, head}
          other -> {:error, %{reason: "could not read main's HEAD: #{inspect(other)}"}}
        end

      _ ->
        {:error, %{reason: "the project has no main working copy"}}
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
