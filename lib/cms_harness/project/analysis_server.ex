defmodule CmsHarness.Project.AnalysisServer do
  @moduledoc """
  One project's analyzer queue: runs the tools the server asked for, one at a
  time, and pushes each result back as it lands.

  **Serialized, not parallel.** `mix test` and `mix spex` share `_build/test`,
  and two mix runs at once can corrupt the build into reporting failures that
  are not in the code. The server's `Analysis.ProjectServer` serializes for
  the same reason.

  **Every request is answered, with a real result.** A run the server started
  is a `:running` row in its ledger; one nobody finishes makes the stop hook
  report analysis pending forever. So a crash, a timeout, a cancel and a tool
  that will not start all push a result saying so, and a duplicate request for
  a source already queued ties onto that entry and receives its real result.

  Runs execute in a task under the project's `Task.Supervisor`, so a wedged
  `mix` cannot take the queue with it when it is killed.
  """

  use GenServer

  require Logger

  alias CmsHarness.Analysis
  alias CmsHarness.AnalysisSlots
  alias CmsHarness.Channel
  alias CmsHarness.Sync
  alias CodeMySpec.Environments.Environment

  # A ceiling, not an expectation: it bounds the run that will never finish,
  # which would otherwise hold every later analyzer behind it.
  @default_timeout :timer.minutes(30)

  # --- Client ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    GenServer.start_link(__MODULE__, project, name: via(project.root))
  end

  # Keyed on the working copy, not the project: two checkouts of one project
  # resolve the same id.
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
  Stop everything this project's queue holds: the run under way is killed, and
  it and every run queued behind it are answered as superseded, with `reason`.

  The promotion gate asks for this when a batch leaves its copy, so the next
  batch does not rebuild the tree under runs still holding machine-wide slots.
  Returns how many entries were held.
  """
  @spec cancel(String.t(), String.t()) :: non_neg_integer()
  def cancel(root, reason) when is_binary(reason) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, {:cancel, reason}, 5_000)
      [] -> 0
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

  Declared to the server on join, so its reconnect sweep does not close runs
  that survived a dropped socket and will still report.

  Empty list when there is no server for this root ("declaring nothing").
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

  For the dev dashboard. The server's `analysis_runs` ledger shows each tied
  run as its own `:running` row; only this queue knows they are one execution.

  `nil` when there is no queue for this root.
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

  # Queued and tied runs count as in flight. Their rows are already `:running`
  # on the server, so a sweep would close them just the same, and this server
  # will answer them.
  def handle_call(:in_flight, _from, state) do
    {:reply, held_run_ids(state), state}
  end

  def handle_call({:cancel, reason}, _from, state) do
    held = Enum.reject([state.running | state.queue], &is_nil/1)

    if running = state.running do
      Task.Supervisor.terminate_child(Sync.task_supervisor(state.project.root), running.task.pid)
      Process.demonitor(running.task.ref, [:flush])
    end

    for entry <- held, run_id <- [entry.run_id | Map.get(entry, :tied_run_ids, [])] do
      Channel.deliver_analysis_result(state.project.root, %{
        "run_id" => run_id,
        "source" => entry.source,
        "status" => "superseded",
        "error" => reason
      })
    end

    if held != [] do
      Logger.info(
        "[CmsHarness] cancelled #{length(held)} analyzer run(s) for #{state.project.root}: #{reason}"
      )
    end

    {:reply, length(held), clear_running(%{state | queue: []})}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{running: entry_summary(state.running), queued: Enum.map(state.queue, &entry_summary/1)},
     state}
  end

  @impl true
  def handle_info(
        {ref, {:ran, result, completed}},
        %{running: %{task: %Task{ref: ref}} = running} = state
      ) do
    Process.demonitor(ref, [:flush])
    deliver(state, running, result, completed)
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  # The commit the analyzer is starting on, for the server to record against
  # this run and every run tied to it. Guarded on `run_id` like
  # `:slot_acquired`, so a start from a run already moved past is not reported.
  def handle_info(
        {:analysis_started, run_id, tree},
        %{running: %{run_id: run_id, source: source} = running} = state
      ) do
    for id <- [run_id | Map.get(running, :tied_run_ids, [])] do
      Channel.deliver_analysis_started(state.project.root, %{
        "run_id" => id,
        "source" => source,
        "start_commit" => tree.commit,
        "start_tree_dirty" => tree.dirty
      })
    end

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: %{task: %Task{ref: ref}} = running} = state
      ) do
    # The task died without returning. Answered rather than dropped.
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

  # Arms the kill timer when the analyzer actually starts, not at dispatch, so
  # waiting for a machine-wide slot spends none of the run's budget. Guarded on
  # `run_id` so a message from a run already moved past cannot arm a timer for
  # the next. Logs how a long wait ended; short waits are not worth a line.
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

  # Strips the live `Task`. Carries the `tied_run_ids` themselves so a
  # dashboard can correlate them with the server's `analysis_runs` rows.
  defp entry_summary(nil), do: nil

  defp entry_summary(entry) do
    %{
      source: entry.source,
      run_id: entry.run_id,
      args: Map.get(entry, :args, []),
      tied_run_ids: Map.get(entry, :tied_run_ids, [])
    }
  end

  # Queue rules:
  # - a run id already held is ignored (the server re-sends runs it has joined);
  # - a source already *queued* ties onto that entry: one execution answers
  #   every tied run id with the same real result;
  # - otherwise a new entry, including for a source that is only *running*,
  #   since that run may be answering input now stale.
  # See knowledge/harness/channel, "Analysis queue".
  defp accept(request, state) do
    case parse(request) do
      {:ok, run_id, source, args} ->
        cond do
          # The server re-sends a run it has joined; a second entry would push
          # its result twice.
          holds_run?(state, run_id) ->
            state

          queued_entry_for(state, source) ->
            tie_to_queued(state, source, run_id, args)

          true ->
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

  # One queued entry per source: at most current run + next run. The next
  # run's args grow to the union of everyone tied to it, so no tied request's
  # files go unanalyzed.
  defp tie_to_queued(state, source, run_id, args) do
    Logger.info(
      "[CmsHarness] #{source} is already queued for #{state.project.root} — " <>
        "run #{run_id} is tied to it and will get its result"
    )

    queue =
      Enum.map(state.queue, fn
        %{source: ^source} = entry ->
          %{
            entry
            | tied_run_ids: [run_id | entry.tied_run_ids],
              args: merge_args(entry.args, args)
          }

        entry ->
          entry
      end)

    %{state | queue: queue}
  end

  # Empty args mean "the whole suite", a superset of any file list, so it wins
  # the merge. Two non-empty lists merge to their union.
  defp merge_args([], _other), do: []
  defp merge_args(_args, []), do: []
  defp merge_args(args, other), do: Enum.uniq(args ++ other)

  defp parse(%{"run_id" => run_id, "source" => source} = request)
       when is_integer(run_id) and is_binary(source) do
    {:ok, run_id, source, List.wrap(Map.get(request, "args", []))}
  end

  defp parse(request), do: {:error, request}

  # Only the queue, deliberately not `state.running`: a duplicate of a running
  # source becomes a new entry that later duplicates tie onto.
  defp queued_entry_for(state, source), do: Enum.find(state.queue, &(&1.source == source))

  defp holds_run?(state, run_id), do: run_id in held_run_ids(state)

  # Every run id this queue will answer: each entry's own and everything tied
  # to it.
  defp held_run_ids(state) do
    [state.running | state.queue]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&[&1.run_id | Map.get(&1, :tied_run_ids, [])])
  end

  # Cheapest first, so the fast analyzers an agent can act on are not stuck
  # behind spex. Ordering rather than a second slot: two concurrent `mix`
  # runs contend for `_build`.
  # See knowledge/harness/channel, "Analysis queue".
  @cost %{"compiler" => 0, "credo" => 1, "exunit" => 2, "spex" => 3}

  @doc """
  Public only so the ordering can be tested without standing up a server.
  """
  def insert_by_cost(queue, entry) do
    # Cheapest first *among what arrived together*, never ahead of something
    # already waiting; otherwise a stream of cheap requests starves spex.
    # `waiting` is every entry that has survived a batch (`settled`); absent
    # reads as unsettled, so hand-built entries in tests sort by cost.
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

  # No timer armed here: `:slot_acquired` arms it once the run has a slot.
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

  # Inside the task, so the slot is held by the process doing the work and is
  # released when it exits, including when the timer kills it.
  # `AnalysisSlots.acquire/1` waits for a slot; `:slot_acquired` is sent only on
  # `:ok`, since a `:busy` never ran. `:busy` is still answered, as an error.
  defp run_with_slot(project, entry, parent) do
    requested_at = System.monotonic_time(:millisecond)

    case AnalysisSlots.acquire(AnalysisSlots.lane(entry.source, entry.args)) do
      :ok ->
        waited_ms = System.monotonic_time(:millisecond) - requested_at
        send(parent, {:slot_acquired, entry.run_id, waited_ms})

        # The checkout's git state either side of the run, so the server can
        # record which commit the answer is for.
        env = Environment.new(:local, project.root)
        send(parent, {:analysis_started, entry.run_id, Analysis.tree_state(env)})
        result = Analysis.run(project, entry.source, entry.args, entry.run_id)
        {:ran, result, Analysis.tree_state(env)}

      :busy ->
        {:ran,
         {:error,
          "this machine could not free one of its #{AnalysisSlots.limit()} analyzer " <>
            "slots within #{AnalysisSlots.wait_ceiling()}ms — more running at once makes " <>
            "every one of them report failures that are the load rather than the code. " <>
            "Nothing ran. The next stop re-enqueues this."}, nil}
    end
  end

  defp clear_running(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | running: nil, timer: nil}
  end

  # Every tied run_id gets the same real result as the primary. `tied_to` is
  # `nil` for the primary and the primary's run_id for tied ones: only the
  # owner's message reconciles Problems, so one execution is reconciled once.
  #
  # `completed` is the checkout's git state when the analyzer finished; nil
  # when it never returned. `"args"` is what actually ran (a tie merges args),
  # and the server decides what the result replaces from it.
  defp deliver(state, running, result, completed \\ nil) do
    tree = completed |> completed_tree() |> Map.put("args", Map.get(running, :args))
    push_result(state.project.root, running.run_id, running.source, result, nil, tree)

    for run_id <- Map.get(running, :tied_run_ids, []) do
      push_result(state.project.root, run_id, running.source, result, running.run_id, tree)
    end
  end

  defp completed_tree(%{commit: commit}) when is_binary(commit),
    do: %{"completed_commit" => commit}

  defp completed_tree(_completed), do: %{}

  # Carries `analyzer_staleness`: a harness runs the analyzer it booted with,
  # and a stale analyzer's findings otherwise look like ordinary stale
  # findings. Sent rather than logged, because the agent reads the result, not
  # the harness log.
  defp push_result(root, run_id, source, {:ok, result}, tied_to, tree) do
    Channel.deliver_analysis_result(
      root,
      Map.merge(tree, %{
        "run_id" => run_id,
        "source" => source,
        "status" => "ok",
        "result" => result,
        "analyzer_staleness" => CodeMySpec.BootVersion.analyzer_staleness(),
        "tied_to" => tied_to
      })
    )
  end

  # A failure never reconciles Problems, so `tied_to` is irrelevant; every tied
  # run_id still needs its own row closed.
  defp push_result(root, run_id, source, {:error, reason}, _tied_to, tree) do
    Logger.error("[CmsHarness] #{source} run #{run_id} did not produce a result: #{reason}")

    Channel.deliver_analysis_result(
      root,
      Map.merge(tree, %{
        "run_id" => run_id,
        "source" => source,
        "status" => "error",
        "error" => to_string(reason)
      })
    )
  end

  defp push_result(root, run_id, source, other, tied_to, tree) do
    push_result(
      root,
      run_id,
      source,
      {:error, "unreadable analyzer result: #{inspect(other)}"},
      tied_to,
      tree
    )
  end

  defp timeout,
    do: Application.get_env(:code_my_spec, :harness_analysis_timeout, @default_timeout)
end
