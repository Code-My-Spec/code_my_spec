defmodule CmsHarness.Project.AnalysisServer do
  @moduledoc """
  One project's analyzer queue: runs the tools the server asked for, one at a
  time, and pushes each result back as it lands.

  **Serialized, not parallel.** `mix test` and `mix spex` share `_build/test`,
  and a project on an older Elixir has no OS-level build lock, so two mix runs
  at once can corrupt the build — and a corrupted build reports failures that
  are not in the code. The server's own `Analysis.ProjectServer` serializes for
  exactly this reason; this is the same rule on the machine that now does the
  running.

  **Every request is answered, with a real result.** A run the server started
  is a `:running` row in its ledger, and a row nobody finishes makes the stop
  hook report analysis pending forever — which allows every stop with a note
  that results will apply next time, on a next time that never comes. So a
  crash, a timeout, and a tool that will not start all push a result saying
  so. A duplicate request for a source already queued is never dropped
  either: it ties onto the entry already waiting and receives that entry's
  real result when it lands, story 839 (`CodeMySpec.Analysis`'s own
  moduledoc: "the single execution path shared by the stop hook and
  model-invoked test runs"). Silence, and an answer with no data in it, are
  the two things this must never give.

  Runs execute in a task under the project's `Task.Supervisor`, so a wedged
  `mix` cannot take the queue with it when it is killed.
  """

  use GenServer

  require Logger

  alias CmsHarness.Analysis
  alias CmsHarness.AnalysisSlots
  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Sync

  # Generous, and a ceiling rather than an expectation: a full suite on a cold
  # `_build` is minutes. What it is really for is the run that will never
  # finish, which without this holds every later analyzer behind it.
  @default_timeout :timer.minutes(30)

  # --- Client ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    GenServer.start_link(__MODULE__, project, name: via(project.root))
  end

  # Keyed on the working copy, not the project: two checkouts of one project
  # resolve the same id, and keying on that gave the second one the first's
  # queue. Issue 8b83ba20.
  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:analysis, root}}}

  @doc """
  Queue the runs the server asked for.

  Each entry is `%{"run_id" => id, "source" => source, "args" => args}`. Returns
  `:ok` whether or not the project is being served — a push for a project this
  harness does not hold is the server's business to notice, not something to
  crash a channel over.
  """
  @spec enqueue(String.t(), [map()]) :: :ok
  def enqueue(root, runs) when is_list(runs) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:enqueue, runs})

      [] ->
        Logger.error(
          "[CmsHarness] the server asked project #{root} to run " <>
            "#{length(runs)} analyzer(s), but this harness has no analysis queue for it. " <>
            "Those runs will sit unfinished on the server."
        )

        :ok
    end
  end

  @doc """
  Test seam: block until the queue is empty. Not used in production — the
  server learns a run finished by being told, not by anyone waiting.
  """
  @spec idle?(String.t()) :: boolean()
  def idle?(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :idle?, 5_000)
      [] -> true
    end
  end

  @doc """
  Run ids this harness is still working on — the one executing plus everything
  queued behind it.

  Declared to the server on join. The server closes a working copy's open runs
  when a harness reconnects, on the reasoning that its queue went with it; that
  is right for a harness that restarted and wrong for one whose socket dropped,
  because the analyzers are OS processes here and a closed socket does not touch
  them. They finish, report, and the result is refused for a run that is no
  longer `:running`.

  Empty list when there is no server for this root, which reads as "declaring
  nothing" and leaves the sweep exactly as it was.
  """
  @spec in_flight(String.t()) :: [integer()]
  def in_flight(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :in_flight, 5_000)
      [] -> []
    end
  end

  @doc """
  A snapshot of what this project's queue actually believes right now: the
  one entry executing (or waiting for a machine-wide slot) and everything
  tied to it, plus every other source still queued behind it.

  For the dev dashboard. The server's own `analysis_runs` ledger cannot
  answer this — every entry tied to a source reads as its own `:running`
  row, so four ties on one execution look like four things happening at
  once. This is the one place that actually knows there is one.

  `nil` when nothing is queued for this root, which reads as "asked and
  there is nothing to say" rather than an error.
  """
  @spec status(String.t()) :: %{running: map() | nil, queued: [map()]} | nil
  def status(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :status, 5_000)
      [] -> nil
    end
  end

  # --- Server ---

  @impl true
  def init(project) do
    {:ok, %{project: project, running: nil, queue: [], timer: nil}}
  end

  @impl true
  def handle_cast({:enqueue, runs}, state) do
    state =
      runs
      |> Enum.reduce(state, &accept/2)
      |> settle()
      |> maybe_start_next()

    {:noreply, state}
  end

  @impl true
  def handle_call(:idle?, _from, state) do
    {:reply, is_nil(state.running) and state.queue == [], state}
  end

  # Queued runs count as in flight. Their rows are already `:running` on the
  # server — it opens one per dispatched request — so a sweep would close them
  # just the same, and this server will get to them.
  def handle_call(:in_flight, _from, state) do
    running = if state.running, do: [state.running.run_id], else: []
    {:reply, running ++ Enum.map(state.queue, & &1.run_id), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{running: entry_summary(state.running), queued: Enum.map(state.queue, &entry_summary/1)}, state}
  end

  @impl true
  def handle_info({ref, result}, %{running: %{task: %Task{ref: ref}} = running} = state) do
    Process.demonitor(ref, [:flush])
    deliver(state, running, result)
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: %{task: %Task{ref: ref}} = running} = state
      ) do
    # The task died without returning. Answered rather than dropped: an
    # unanswered run is a ledger row that stays `:running` and a stop hook that
    # reports analysis pending forever.
    deliver(state, running, {:error, "analyzer task died: #{inspect(reason)}"})
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  def handle_info({:timeout, run_id}, %{running: %{run_id: run_id} = running} = state) do
    Logger.error(
      "[CmsHarness] #{running.source} for #{state.project.root} exceeded #{timeout()}ms — killing it"
    )

    Task.Supervisor.terminate_child(Sync.task_supervisor(state.project.root), running.task.pid)
    Process.demonitor(running.task.ref, [:flush])
    deliver(state, running, {:error, "analyzer timed out after #{timeout()}ms"})
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  # Arms the kill timer the moment the analyzer actually starts, not the
  # moment it was dispatched — the seam that lets `AnalysisSlots.acquire/0`
  # wait for a machine-wide slot without spending the run's own budget
  # waiting for one (story 839, criterion 3440). Guarded on `run_id` so a
  # message from a run this server has already moved past (superseded by a
  # kill, or already delivered) cannot arm a timer for whatever runs next.
  #
  # Logged, not just armed. `AnalysisSlots` logs the *start* of a wait ("an
  # analyzer run is waiting for a machine-wide slot") but nothing ever said
  # how it ended — a reader saw the wait begin and had no line telling them
  # it resolved, how long it took, or that this exact run is what the timer
  # is now counting for. `waited_ms` only worth naming past a few hundred
  # milliseconds: most runs acquire a slot immediately, and logging "waited
  # 2ms" for every single one would bury the ones that actually waited.
  def handle_info(
        {:slot_acquired, run_id, waited_ms},
        %{running: %{run_id: run_id, source: source}} = state
      ) do
    if waited_ms > 500 do
      Logger.info(
        "[CmsHarness] #{source} run #{run_id} for #{state.project.root} got a machine-wide " <>
          "slot after waiting #{waited_ms}ms — starting now, kill timer armed from here"
      )
    end

    timer = Process.send_after(self(), {:timeout, run_id}, timeout())
    {:noreply, %{state | timer: timer}}
  end

  def handle_info({:slot_acquired, _run_id, _waited_ms}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # --- Internals ---

  # Strips the live `Task` struct (a pid/ref, not meaningful off-process).
  # Carries the actual `tied_run_ids`, not just their count — a dashboard
  # correlating this against the server's own `analysis_runs` rows needs
  # every id riding on this one execution, not a number to re-derive nothing
  # from.
  defp entry_summary(nil), do: nil

  defp entry_summary(entry) do
    %{
      source: entry.source,
      run_id: entry.run_id,
      args: Map.get(entry, :args, []),
      tied_run_ids: Map.get(entry, :tied_run_ids, [])
    }
  end

  # Two `mix test` processes in one `_build` is the corruption this server
  # exists to prevent, and the queue is what prevents it: `maybe_start_next/1`
  # only starts when nothing is running. So a request for a source that is
  # merely *running* can be queued rather than refused.
  #
  # It used to be refused, and the refusal was delivered as an error, which
  # failed the run row and left the previous result standing as the newest the
  # validator had. With a 30-minute analyzer timeout and an agent stopping
  # every minute or two, one run wedged on the `_build` lock poisoned every
  # stop in that window: the hook blocked on stale findings describing code
  # that was already fixed, and no rerun could replace them. Five stops in a
  # row, escapable only by clearing the stored problems by hand.
  #
  # A request for a source already queued is never a second queue entry — it
  # ties onto the one already waiting, so N duplicate requests for one source
  # cost one execution instead of N (or, before this, N empty "superseded"
  # answers: 397 against 25 completed in ninety minutes on Broken Oaths
  # 2026-09-08, and no spex sweep finishing for thirty-four minutes on a suite
  # that takes under three — John: "We can't be superseding runs like that. We
  # have to let it finish."). When the tied entry finally runs, every run_id
  # tied to it receives the same real result `deliver/3` sends the primary
  # one — never a synthetic status carrying no data.
  #
  # A request for a source that is merely *running*, with nothing yet queued
  # behind it, needs no separate case: falling through to the plain "insert a
  # new entry" branch below both starts it once the current run finishes
  # (`maybe_start_next/1`'s ordinary behaviour) and gives every *further*
  # duplicate something to tie onto — this new entry, not the run already in
  # flight, because that run may be answering input now stale relative to
  # what prompted these requests.
  defp accept(request, state) do
    case parse(request) do
      {:ok, run_id, source, args} ->
        case queued_entry_for(state, source) do
          %{} ->
            tie_to_queued(state, source, run_id, args)

          nil ->
            entry = %{
              run_id: run_id,
              tied_run_ids: [],
              source: source,
              args: args,
              settled: false
            }

            %{state | queue: insert_by_cost(state.queue, entry)}
        end

      {:error, request} ->
        Logger.error("[CmsHarness] unreadable run_analysis entry: #{inspect(request)}")
        state
    end
  end

  # One queued "next" entry per source, ever — its arg set grows to cover
  # every tied request, its identity does not. Without this, a second
  # request naming files the first queued request never named got answered
  # with the first request's result and its own files were never actually
  # analyzed — silently, since `tied_run_ids` alone gave every tied run_id
  # the same real (but incomplete) result, and "real, not synthetic" was the
  # only thing being checked for. Story 839, John 2026-09-13: one source
  # never needs more than two entries — current run, next run — and the
  # next run's scope is the union of everyone tied to it.
  defp tie_to_queued(state, source, run_id, args) do
    Logger.info(
      "[CmsHarness] #{source} is already queued for #{state.project.root} — " <>
        "run #{run_id} is tied to it and will get its result"
    )

    queue =
      Enum.map(state.queue, fn
        %{source: ^source} = entry ->
          %{entry | tied_run_ids: [run_id | entry.tied_run_ids], args: merge_args(entry.args, args)}

        entry ->
          entry
      end)

    %{state | queue: queue}
  end

  # Empty args mean "the whole suite" — a superset of any file list, so it
  # wins the merge rather than being unioned away. Two non-empty lists merge
  # to their union: the next run has to cover every file anyone tied to it
  # actually asked about.
  defp merge_args([], _other), do: []
  defp merge_args(_args, []), do: []
  defp merge_args(args, other), do: Enum.uniq(args ++ other)

  defp parse(%{"run_id" => run_id, "source" => source} = request)
       when is_integer(run_id) and is_binary(source) do
    {:ok, run_id, source, List.wrap(Map.get(request, "args", []))}
  end

  defp parse(request), do: {:error, request}

  # Only the queue, deliberately not `state.running` too. A source that is
  # merely running has nothing queued to tie onto yet — the first duplicate
  # request for it falls through `accept/2` to the plain insert branch, which
  # both starts it once the current run finishes and becomes what any
  # *further* duplicate ties onto. Checking `running` here as well would make
  # this true too early and change nothing about what gets created.
  defp queued_entry_for(state, source), do: Enum.find(state.queue, &(&1.source == source))

  # Cheapest first. Measured on this harness: compiler ~9s, credo ~10s,
  # exunit ~2m10s, spex ~2m35s — more than an order of magnitude between the
  # ends, and the two an agent can act on immediately were the two arriving
  # last.
  #
  # Head-of-line blocking here does not read as slowness, it reads as wrong
  # feedback that looks authoritative. A credo finding fixed and verified came
  # back five stops running, correctly marked stale, each stop saying a rerun
  # would replace it — and each rerun sat behind spex, so the replacement never
  # arrived inside the working session. An agent that trusts that re-edits
  # correct code; one that learns to distrust it stops reading the source that
  # would catch a real regression.
  #
  # Ordering rather than a second slot, deliberately: two concurrent `mix`
  # invocations contend for the same `_build` (c032af74), so parallelism would
  # buy latency by making a worse failure more likely.
  @cost %{"compiler" => 0, "credo" => 1, "exunit" => 2, "spex" => 3}

  @doc """
  Public only so the ordering can be tested without standing up a server and
  timing four real analyzers. Named apart from the client-API `enqueue/2`
  above: same name and arity, entirely different meaning, and they resolved
  to the right clause only because one guards on `is_list`.
  """
  def insert_by_cost(queue, entry) do
    # Cheapest first *among what is waiting together*, and never ahead of
    # something that was already waiting.
    #
    # This sorted the whole queue on every arrival, so a compiler request
    # landing while spex sat queued went in front of it. That is right for one
    # batch — the two an agent can act on immediately should arrive first — and
    # wrong the moment requests keep coming, because the cheap one keeps
    # arriving and the expensive one never reaches the front.
    #
    # Measured on Broken Oaths 2026-09-08, after in-flight runs were allowed to
    # finish: six compiler sweeps completed in thirty seconds and not one spex
    # sweep, on a copy whose coding agent was blocked waiting for exactly that
    # spex result. `bdd_specs_passing` needs a fresh one to latch, so the
    # requirement could not be satisfied by any amount of correct work.
    #
    # `waiting` is everything that has been in the queue at least one arrival;
    # a new entry sorts only against the arrivals it shares a batch with, which
    # is what `@cost` was reasoning about in the first place.
    # Absent reads as unsettled, so a caller building an entry by hand — every
    # direct test of this ordering — still sorts the way the cost table says.
    {waiting, arriving} = Enum.split_while(queue, &Map.get(&1, :settled, false))

    sorted =
      (arriving ++ [entry])
      |> Enum.sort_by(&Map.get(@cost, &1.source, 9))

    waiting ++ sorted
  end

  # Everything currently queued has now waited through an arrival, so the next
  # one sorts behind it rather than in front. Called when a batch is done.
  defp settle(%{queue: queue} = state),
    do: %{state | queue: Enum.map(queue, &Map.put(&1, :settled, true))}

  # No timer armed here any more — `run_with_slot/3` reports back once it
  # actually has a slot, and `handle_info({:slot_acquired, _, _}, _)` arms it
  # then. Arming at dispatch was what forced `AnalysisSlots.acquire/0` to
  # refuse instantly rather than wait: a run queued behind others would have
  # spent the kill budget waiting and been killed for being slow (story 839,
  # criterion 3440).
  defp maybe_start_next(%{running: nil, queue: [entry | rest]} = state) do
    project = state.project
    parent = self()

    task =
      Task.Supervisor.async_nolink(Sync.task_supervisor(project.root), fn ->
        run_with_slot(project, entry, parent)
      end)

    %{state | running: Map.put(entry, :task, task), queue: rest, timer: nil}
  end

  defp maybe_start_next(state), do: state

  # Inside the task, so the slot is held by the process doing the work and comes
  # back when it exits — including when the thirty-minute timer kills it.
  #
  # `acquire/0` now waits for a slot rather than refusing instantly (story 839,
  # criterion 3440) — the timer moved to `parent`'s own arming, above, so
  # waiting here spends none of the run's kill budget. `:slot_acquired` is
  # what tells `parent` the wait is over and the clock should start; sent only
  # on `:ok`, because a `:busy` past `AnalysisSlots.wait_ceiling/0` never
  # actually ran and has nothing for a kill timer to bound.
  #
  # An error tuple rather than a silent skip either way, because this
  # module's own rule is that every request is answered: a run the server
  # started is a `:running` row in its ledger, and one nobody finishes makes
  # the stop hook report analysis pending forever.
  defp run_with_slot(project, entry, parent) do
    requested_at = System.monotonic_time(:millisecond)

    case AnalysisSlots.acquire() do
      :ok ->
        waited_ms = System.monotonic_time(:millisecond) - requested_at
        send(parent, {:slot_acquired, entry.run_id, waited_ms})
        Analysis.run(project, entry.source, entry.args, entry.run_id)

      :busy ->
        {:error,
         "this machine could not free one of its #{AnalysisSlots.limit()} analyzer " <>
           "slots within #{AnalysisSlots.wait_ceiling()}ms — more running at once makes " <>
           "every one of them report failures that are the load rather than the code. " <>
           "Nothing ran. The next stop re-enqueues this."}
    end
  end

  defp clear_running(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | running: nil, timer: nil}
  end

  # Every run_id tied to this entry gets the same real result the primary
  # one does — the whole point of tying rather than superseding. `deliver/3`
  # is the only place a tied request's answer is ever actually resolved.
  defp deliver(state, running, result) do
    for run_id <- [running.run_id | Map.get(running, :tied_run_ids, [])] do
      push_result(state.project.root, run_id, running.source, result)
    end
  end

  # The result carries whether the build that produced it is behind the tree it
  # decided about.
  #
  # A harness runs the analyzer it booted with, so a fix to `StaticAnalysis` is
  # not in force until the harness is rebuilt — and from inside the stop loop
  # that is indistinguishable from an ordinary stale finding. `d9f0846c`: three
  # loops spent on findings already fixed, while the compiled pipeline sat
  # eleven commits behind for a whole session. Diagnosing it needed a `.beam`
  # timestamp.
  #
  # Sent rather than logged, because the reader is the agent being told to stop
  # again, and the harness log is the one place it is not looking.
  defp push_result(root, run_id, source, {:ok, result}) do
    ChannelClient.deliver_analysis_result(root, %{
      "run_id" => run_id,
      "source" => source,
      "status" => "ok",
      "result" => result,
      "analyzer_staleness" => CodeMySpec.BootVersion.analyzer_staleness()
    })
  end

  defp push_result(root, run_id, source, {:error, reason}) do
    Logger.error("[CmsHarness] #{source} run #{run_id} did not produce a result: #{reason}")

    ChannelClient.deliver_analysis_result(root, %{
      "run_id" => run_id,
      "source" => source,
      "status" => "error",
      "error" => to_string(reason)
    })
  end

  defp push_result(root, run_id, source, other) do
    push_result(
      root,
      run_id,
      source,
      {:error, "unreadable analyzer result: #{inspect(other)}"}
    )
  end

  defp timeout,
    do: Application.get_env(:code_my_spec, :harness_analysis_timeout, @default_timeout)
end
