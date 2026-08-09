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

  **Every request is answered.** A run the server started is a `:running` row in
  its ledger, and a row nobody finishes makes the stop hook report analysis
  pending forever — which allows every stop with a note that results will apply
  next time, on a next time that never comes. So a crash, a timeout, a tool that
  will not start and a queue that is already busy all push a result saying so.
  Silence is the one answer this must never give.

  Runs execute in a task under the project's `Task.Supervisor`, so a wedged
  `mix` cannot take the queue with it when it is killed.
  """

  use GenServer

  require Logger

  alias CmsHarness.Analysis
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

  @doc false
  # Test seam: block until the queue is empty. Not used in production — the
  # server learns a run finished by being told, not by anyone waiting.
  @spec idle?(String.t()) :: boolean()
  def idle?(root) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, root}) do
      [{pid, _}] -> GenServer.call(pid, :idle?, 5_000)
      [] -> true
    end
  end

  # --- Server ---

  @impl true
  def init(project) do
    {:ok, %{project: project, running: nil, queue: [], timer: nil}}
  end

  @impl true
  def handle_cast({:enqueue, runs}, state) do
    {:noreply, runs |> Enum.reduce(state, &accept/2) |> maybe_start_next()}
  end

  @impl true
  def handle_call(:idle?, _from, state) do
    {:reply, is_nil(state.running) and state.queue == [], state}
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

  def handle_info(_message, state), do: {:noreply, state}

  # --- Internals ---

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
  # A queued run answers "still running" instead, which the stop hook allows —
  # results apply next stop. Still refused is a *second* pending run for one
  # source, which would only deliver the same answer twice.
  defp accept(request, state) do
    case parse(request) do
      {:ok, run_id, source, args} ->
        if queued?(state, source) do
          Logger.warning(
            "[CmsHarness] #{source} is already queued for #{state.project.root} — " <>
              "refusing run #{run_id}"
          )

          push_result(state.project.root, run_id, source, {:error, "already queued"})
          state
        else
          entry = %{run_id: run_id, source: source, args: args}
          %{state | queue: insert_by_cost(state.queue, entry)}
        end

      {:error, request} ->
        Logger.error("[CmsHarness] unreadable run_analysis entry: #{inspect(request)}")
        state
    end
  end

  defp parse(%{"run_id" => run_id, "source" => source} = request)
       when is_integer(run_id) and is_binary(source) do
    {:ok, run_id, source, List.wrap(Map.get(request, "args", []))}
  end

  defp parse(request), do: {:error, request}

  defp queued?(state, source), do: Enum.any?(state.queue, &(&1.source == source))

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

  @doc false
  # Public only so the ordering can be tested without standing up a server and
  # timing four real analyzers. Named apart from the client-API `enqueue/2`
  # above: same name and arity, entirely different meaning, and they resolved
  # to the right clause only because one guards on `is_list`.
  def insert_by_cost(queue, entry) do
    # `sort_by/2` is stable, so two runs of one source keep their arrival order
    # and only the cheap-vs-expensive ordering changes.
    Enum.sort_by(queue ++ [entry], &Map.get(@cost, &1.source, 9))
  end

  defp maybe_start_next(%{running: nil, queue: [entry | rest]} = state) do
    project = state.project

    task =
      Task.Supervisor.async_nolink(Sync.task_supervisor(project.root), fn ->
        Analysis.run(project, entry.source, entry.args)
      end)

    timer = Process.send_after(self(), {:timeout, entry.run_id}, timeout())

    %{state | running: Map.put(entry, :task, task), queue: rest, timer: timer}
  end

  defp maybe_start_next(state), do: state

  defp clear_running(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | running: nil, timer: nil}
  end

  defp deliver(state, running, result) do
    push_result(state.project.root, running.run_id, running.source, result)
  end

  defp push_result(root, run_id, source, {:ok, result}) do
    ChannelClient.deliver_analysis_result(root, %{
      "run_id" => run_id,
      "source" => source,
      "status" => "ok",
      "result" => result
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
