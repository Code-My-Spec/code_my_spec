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
    GenServer.start_link(__MODULE__, project, name: via(project.id))
  end

  def via(project_id), do: {:via, Registry, {CmsHarness.Registry, {:analysis, project_id}}}

  @doc """
  Queue the runs the server asked for.

  Each entry is `%{"run_id" => id, "source" => source, "args" => args}`. Returns
  `:ok` whether or not the project is being served — a push for a project this
  harness does not hold is the server's business to notice, not something to
  crash a channel over.
  """
  @spec enqueue(String.t(), [map()]) :: :ok
  def enqueue(project_id, runs) when is_list(runs) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, project_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:enqueue, runs})

      [] ->
        Logger.error(
          "[CmsHarness] the server asked project #{project_id} to run " <>
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
  def idle?(project_id) do
    case Registry.lookup(CmsHarness.Registry, {:analysis, project_id}) do
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

    Task.Supervisor.terminate_child(Sync.task_supervisor(state.project.id), running.task.pid)
    Process.demonitor(running.task.ref, [:flush])
    deliver(state, running, {:error, "analyzer timed out after #{timeout()}ms"})
    {:noreply, state |> clear_running() |> maybe_start_next()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Internals ---

  # A duplicate request for a source already queued or running is refused
  # rather than run twice: two `mix test` processes in one `_build` is the
  # corruption this server exists to prevent. The refusal is delivered, so the
  # server can fail that run row instead of waiting on it.
  defp accept(request, state) do
    with {:ok, run_id, source, args} <- parse(request) do
      if busy_with?(state, source) do
        Logger.warning(
          "[CmsHarness] #{source} is already running for #{state.project.root} — " <>
            "refusing run #{run_id}"
        )

        push_result(state.project.id, run_id, source, {:error, "already running"})
        state
      else
        %{state | queue: state.queue ++ [%{run_id: run_id, source: source, args: args}]}
      end
    else
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

  defp busy_with?(state, source) do
    running?(state.running, source) or Enum.any?(state.queue, &(&1.source == source))
  end

  defp running?(nil, _source), do: false
  defp running?(running, source), do: running.source == source

  defp maybe_start_next(%{running: nil, queue: [entry | rest]} = state) do
    project = state.project

    task =
      Task.Supervisor.async_nolink(Sync.task_supervisor(project.id), fn ->
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
    push_result(state.project.id, running.run_id, running.source, result)
  end

  defp push_result(project_id, run_id, source, {:ok, result}) do
    ChannelClient.deliver_analysis_result(project_id, %{
      "run_id" => run_id,
      "source" => source,
      "status" => "ok",
      "result" => result
    })
  end

  defp push_result(project_id, run_id, source, {:error, reason}) do
    Logger.error("[CmsHarness] #{source} run #{run_id} did not produce a result: #{reason}")

    ChannelClient.deliver_analysis_result(project_id, %{
      "run_id" => run_id,
      "source" => source,
      "status" => "error",
      "error" => to_string(reason)
    })
  end

  defp push_result(project_id, run_id, source, other) do
    push_result(
      project_id,
      run_id,
      source,
      {:error, "unreadable analyzer result: #{inspect(other)}"}
    )
  end

  defp timeout,
    do: Application.get_env(:code_my_spec, :harness_analysis_timeout, @default_timeout)
end
