defmodule CodeMySpec.PromotionQueue.Worker do
  @moduledoc """
  One project's promotion queue, run one batch at a time.

      idle ─▶ build ─▶ gate ─┬─ green ─▶ land ─▶ idle
                             ├─ pending (analysis running) ─▶ gate again when it lands
                             └─ red ─▶ red on main too? excluded, gate again
                                     ├▶ re-run a lone failure once
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
  alias CodeMySpec.Qa
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @batch_cap 6
  @gate_label "promotion-gate"
  @recheck_ms 120_000
  @retry_ms 300_000
  # Runs of one source that failed at one batch commit before the batch is held:
  # the first, and one retry.
  @max_starts 2
  @hold_ms 900_000
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

  # The gate copy's harness (re)joined. A batch gating there asks again: what
  # it asked before may have gone with the connection that just went.
  def handle_cast(:gate_copy_joined, %{phase: :gating, batch: batch} = state) do
    Logger.info("[PromotionQueue] the gate copy rejoined; asking the gate again at #{batch.head}")
    gate(state)
  end

  def handle_cast(:gate_copy_joined, state), do: handle_cast(:kick, state)

  def handle_cast(:kick, %{phase: :idle} = state), do: next(state)
  def handle_cast(:kick, %{phase: :held} = state), do: retry_held(state)
  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:next, %{phase: :idle} = state), do: next(state)

  # A held batch is built again from scratch: the gate copy may have been set
  # up since, and its counts start over.
  def handle_info(:retry_held, %{phase: :held} = state), do: retry_held(state)
  def handle_info(:retry_held, state), do: {:noreply, state}
  def handle_info(:next, state), do: {:noreply, state}

  def handle_info(:gate, %{phase: :gating, batch: batch} = state) do
    Logger.info("[PromotionQueue] gating #{batch.head}: asking the gate")
    gate(state)
  end

  def handle_info(:gate, state), do: {:noreply, state}

  def handle_info(:land, %{phase: :landing} = state), do: land(state)
  def handle_info(:land, state), do: {:noreply, state}

  # The gate copy's run finished: gate again (or, during a re-run, once the
  # re-run source itself is done).
  def handle_info({:analysis, %{status: :running}}, state), do: {:noreply, state}

  # The gate copy answering a baseline re-run (`check_baseline/3`).
  def handle_info(
        {:analysis, %{working_copy_id: id, source: source}},
        %{phase: :baseline, batch: %{gate: %{id: id}, baseline: {at, asked}}} = state
      ) do
    asked = %{asked | pending: MapSet.delete(asked.pending, source)}

    cond do
      MapSet.size(asked.pending) > 0 -> {:noreply, put_in(state.batch.baseline, {at, asked})}
      at == :at_base -> back_to_head(state, asked)
      true -> settle_baseline(state, asked)
    end
  end

  # The re-run never answered: the gate copy is put back at the batch commit and
  # the findings triaged as found.
  def handle_info(:baseline_timeout, %{phase: :baseline, batch: batch} = state) do
    Logger.warning(
      "[PromotionQueue] the baseline re-run for #{batch.head} never answered; triaging as found"
    )

    batch = %{batch | baseline: :checked}

    case restore_head(batch) do
      :ok -> gate(%{state | phase: :gating, batch: batch})
      {:error, reason} -> could_not_restore(state, reason)
    end
  end

  def handle_info(:baseline_timeout, state), do: {:noreply, state}

  # Gated again only once nothing is still open on the gate copy: the gate
  # starts any source without an answer, and one dispatched but not yet begun
  # has none, so re-gating on every result would start it twice.
  def handle_info({:analysis, %{working_copy_id: id} = run}, %{batch: %{gate: %{id: id}}} = state) do
    cond do
      Analysis.running_on?(state.batch.scope) -> {:noreply, state}
      state.phase == :gating -> gate(state)
      state.phase == {:rerun, run.source} -> gate(%{state | phase: :gating})
      true -> {:noreply, state}
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
             scope_for(scope, gate),
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
         {:ok, %{head: head}} <- Runner.precheck(own, root, copy.id, base),
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
         {:ok, built} <-
           Runner.build_batch(
             gate_scope,
             gate.root,
             base,
             Enum.map(entries, & &1.commit),
             gate.id
           ) do
      merged = MapSet.new(built.merged)

      for %{commit: commit, files: files} <- built.conflicted,
          entry <- Enum.filter(entries, &(&1.commit == commit)),
          do: eject(state.scope, entry, conflict_reason(files))

      case Enum.filter(entries, &MapSet.member?(merged, &1.commit)) do
        [] -> next(state)
        in_batch -> gating(state, in_batch, gate, base, built.head)
      end
    else
      {:error, reason} -> could_not_build(state, reason)
    end
  end

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
      reran?: false,
      # Whether main's own red has been asked about (`check_baseline/3`), and
      # the findings main is red on too, which refuse nothing.
      baseline: :unchecked,
      excluded: MapSet.new(),
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
    {:noreply, recheck_later(%{state | phase: :gating, batch: batch})}
  end

  defp could_not_build(state, reason) do
    Logger.error("[PromotionQueue] could not build a batch: #{describe(reason)}; retrying")
    {:noreply, retry_later(%{state | phase: :idle, batch: nil})}
  end

  defp conflict_reason(files) do
    "it conflicts with main or with a candidate ahead of it in the queue" <>
      if(files == [], do: ".", else: ", in #{Enum.join(files, ", ")}.") <>
      " Merge main into your branch, resolve it, and promote again."
  end

  # -- Gate -------------------------------------------------------------------

  defp gate(%{batch: batch} = state) do
    state = cancel_timer(state)

    case Promotion.gate(batch.scope, batch.head, excluding: batch.excluded) do
      {:ok, swept} -> stories_green(state, swept)
      {:pending, pending} -> pending(state, Map.get(pending, :started, []))
      {:error, reason} -> red(state, reason)
    end
  end

  # The gate starts a source with no answer at the batch commit. A source whose
  # runs there keep failing — an analyzer that cannot run on the gate copy (a
  # missing env, a broken toolchain) — would be started again every recheck,
  # forever, so after `@max_starts` failures at that commit the batch is held:
  # not the candidates' fault, so nothing is ejected.
  #
  # Counted from the runs at that commit, not from starts: every landing
  # restarts the harness, which orphans the next gate's first runs, and counting
  # those held a batch whose analyzers ran fine (3c59be47, 2026-10-05).
  defp pending(%{batch: batch} = state, started) do
    case Enum.filter(
           started,
           &(Analysis.failed_at_commit(batch.scope, &1, batch.head, batch.since) >= @max_starts)
         ) do
      [] -> {:noreply, recheck_later(state)}
      failing -> hold(state, failing)
    end
  end

  defp hold(%{batch: batch} = state, sources) do
    why = Enum.map_join(sources, "\n\n", &cannot_run(batch.scope, &1))

    Logger.error(
      "[PromotionQueue] holding the batch at #{batch.head}: the gate copy " <>
        "#{batch.gate.root} cannot run #{Enum.join(sources, ", ")}.\n#{why}"
    )

    for entry <- batch.entries do
      tell(
        state.scope,
        entry,
        "Your promotion of #{subject(entry)} is waiting: the gate copy cannot run " <>
          "#{Enum.join(sources, ", ")}, so nothing can be certified. This is not a " <>
          "finding against your work and nothing was taken out; it is retried " <>
          "when the gate copy is fixed. Do not promote again."
      )
    end

    {:noreply, cancel_timer(state) |> Map.put(:phase, :held) |> hold_later()}
  end

  defp cannot_run(scope, source) do
    case Analysis.latest_run(scope, source) do
      %{output: output} when is_binary(output) and output != "" ->
        "#{source}: …#{String.slice(output, -800, 800)}"

      _ ->
        "#{source}: its runs fail with no output"
    end
  end

  defp retry_held(%{batch: batch} = state) do
    requeue(batch.entries)
    next(%{cancel_timer(state) | phase: :idle, batch: nil})
  end

  defp hold_later(state), do: %{state | timer: Process.send_after(self(), :retry_held, @hold_ms)}

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
    problems = Promotion.blocking_problems_at(batch.scope, batch.head, batch.excluded)

    cond do
      problems == [] ->
        # Not a finding about the code: the gate could not run (an analyzer
        # would not start, the tree was dirty). Nothing to eject; try again.
        Logger.error("[PromotionQueue] gate could not run: #{describe(reason)}; retrying")
        requeue(batch.entries)
        {:noreply, retry_later(%{state | phase: :idle, batch: nil})}

      ask_main?(batch, problems) ->
        check_baseline(state, problems, reason)

      match?({:rerun, _}, Triage.lone_failure(problems)) and not batch.reran? ->
        {:rerun, source} = Triage.lone_failure(problems)
        Logger.info("[PromotionQueue] one #{source} finding at #{batch.head}; re-running it once")
        batch = %{batch | reran?: true}

        case Analysis.start_run(batch.scope, source, [], requested_by: %{kind: "promotion"}) do
          {:error, why} ->
            Logger.info(
              "[PromotionQueue] the re-run did not start (#{inspect(why)}); triaging as found"
            )

            triage(%{state | batch: batch}, problems)

          _started ->
            {:noreply, %{state | phase: {:rerun, source}, batch: batch}}
        end

      true ->
        triage(state, problems)
    end
  end

  # Is main red there too?
  #
  # 87bc9721, 2026-10-05: story 1060's criteria were latched on its own copy,
  # where they pass, before its implementation landed — so main carried a red
  # spex every batch inherited, and whichever candidate gated next was ejected
  # for it. A finding main shares is no candidate's.
  #
  # Asked in the gate copy, which is the queue's own, clean, and idle while its
  # batch is red: reset to `base`, the failing tests are run there; then reset
  # to the batch commit and run again there — which puts the head's findings
  # back, since problems are kept per copy, and is the batch's one re-run of a
  # failure that might be a flake. What reproduced at `base` is excluded and the
  # batch gated again. Once per batch; a step that fails or never answers
  # leaves the findings as found.
  defp check_baseline(%{batch: batch} = state, problems, reason) do
    files = Triage.baseline_files(problems)

    with {:ok, %{head: base}} when base == batch.base <- reset_gate(batch, batch.base),
         asked = %{files: files, pending: MapSet.new(start_runs(batch.scope, files))},
         true <- MapSet.size(asked.pending) > 0 do
      Logger.info(
        "[PromotionQueue] #{length(problems)} finding(s) at #{batch.head}; re-running " <>
          "#{Enum.join(asked.pending, ", ")} at main (#{batch.base}) to see whether it is " <>
          "red there too"
      )

      {:noreply,
       %{
         cancel_timer(state)
         | phase: :baseline,
           batch: %{batch | baseline: {:at_base, asked}},
           timer: Process.send_after(self(), :baseline_timeout, @hold_ms)
       }}
    else
      _ -> unasked(state, reason)
    end
  end

  # Once per batch, for test findings — and only in the queue's own gate copy.
  # The baseline resets the copy it runs in, so never a requester's copy a lone
  # batch was gated on, where someone may still be working (phx-new-generator,
  # 2026-10-05).
  defp ask_main?(batch, problems),
    do:
      batch.baseline == :unchecked and batch.gate.label == @gate_label and
        Triage.baseline_files(problems) != %{}

  # Main could not be asked: back to the batch commit, and triaged as found.
  defp unasked(%{batch: batch} = state, reason) do
    batch = %{batch | baseline: :checked}

    case restore_head(batch) do
      :ok -> red(%{state | batch: batch}, reason)
      {:error, why} -> could_not_restore(state, why)
    end
  end

  defp back_to_head(%{batch: batch} = state, asked) do
    asked = Map.put(asked, :mains, findings_in(batch.scope, asked.files))

    with :ok <- restore_head(batch),
         pending = MapSet.new(start_runs(batch.scope, asked.files)),
         true <- MapSet.size(pending) > 0 do
      {:noreply, put_in(state.batch.baseline, {:at_head, %{asked | pending: pending}})}
    else
      {:error, reason} -> could_not_restore(state, reason)
      false -> settle_baseline(state, asked)
    end
  end

  defp settle_baseline(%{batch: batch} = state, asked) do
    if MapSet.size(asked.mains) > 0 do
      Logger.info(
        "[PromotionQueue] #{MapSet.size(asked.mains)} finding(s) at #{batch.head} are red " <>
          "at main (#{batch.base}) too; not the batch's"
      )
    end

    batch = %{
      batch
      | baseline: :checked,
        reran?: true,
        excluded: MapSet.union(batch.excluded, asked.mains)
    }

    gate(%{cancel_timer(state) | phase: :gating, batch: batch})
  end

  defp start_runs(scope, files) do
    for {source, paths} <- files,
        match?(
          {:ok, _, _},
          Analysis.start_run(scope, source, paths, requested_by: %{kind: "promotion"})
        ),
        do: source
  end

  # The gate copy's blocking findings in `files`, as `Promotion.finding_key/1`s.
  defp findings_in(scope, files) do
    paths = files |> Map.values() |> List.flatten() |> MapSet.new()

    scope
    |> Promotion.blocking_problems()
    |> Enum.filter(&MapSet.member?(paths, &1.file_path))
    |> MapSet.new(&Promotion.finding_key/1)
  end

  # The batch commit is in the gate copy's object store already: resetting to
  # it with nothing to merge is a checkout of exactly that commit.
  defp reset_gate(batch, commit),
    do: Runner.build_batch(batch.scope, batch.gate.root, commit, [], batch.gate.id)

  defp restore_head(batch) do
    case reset_gate(batch, batch.head) do
      {:ok, %{head: head}} when head == batch.head -> :ok
      {:ok, %{head: other}} -> {:error, %{reason: "the gate copy came back at #{other}"}}
      {:error, _} = error -> error
    end
  end

  # The gate copy could not be put back at the batch commit: nothing about the
  # candidates is known, so the batch is built again from scratch.
  defp could_not_restore(%{batch: batch} = state, reason) do
    Logger.error(
      "[PromotionQueue] could not put the gate copy back at #{batch.head}: " <>
        "#{describe(reason)}; rebuilding the batch"
    )

    requeue(batch.entries)
    {:noreply, retry_later(%{cancel_timer(state) | phase: :idle, batch: nil})}
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
        case Runner.changed_files(
               batch.scope,
               batch.gate.root,
               batch.base,
               entry.commit,
               batch.gate.id
             ) do
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

  defp already_on_main(state, entries, head) do
    Logger.info(
      "[PromotionQueue] #{length(entries)} candidate(s) already on main at #{head}; " <>
        "landing them without a gate"
    )

    stories =
      for entry <- entries,
          story = story_of(state.scope, entry),
          do: {story, entry.working_copy_id}

    :ok = Promotion.record_landed_stories(state.scope, stories, main_version(state.scope), head)

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

    next(%{state | phase: :idle, batch: nil})
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
        next(%{state | phase: :idle, batch: nil})

      {:error, _} ->
        then.(state)
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

        next(%{state | phase: :idle, batch: nil})

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
         {:ok, %{version: version}} <- Runner.current(scope_for(scope, main), root, main.id) do
      version
    else
      _ -> nil
    end
  end

  # Main's HEAD, read through main's own copy.
  defp main_head(scope) do
    case WorkingCopies.main(scope) do
      %WorkingCopy{root: root} = main when is_binary(root) ->
        case Runner.current(scope_for(scope, main), root, main.id) do
          {:ok, %{head: head}} when is_binary(head) -> {:ok, head}
          other -> {:error, %{reason: "could not read main's HEAD: #{inspect(other)}"}}
        end

      _ ->
        {:error, %{reason: "the project has no main working copy"}}
    end
  end

  # A scope addressing `copy`: over its harness, or — when the template runs
  # on this machine (the suite) — here.
  defp scope_for(%Scope{environment: %{type: type}} = scope, copy) when type != :harness,
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
