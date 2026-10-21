defmodule CodeMySpecDesktop.Application.Bootstrap do
  @moduledoc "Database-free coordination of prerequisite checks and runtime startup."
  use GenServer

  alias CmsHarness.Setup
  alias CodeMySpecDesktop.Application.Runtime

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def status(server), do: GenServer.call(server, :status)
  def check(server), do: GenServer.call(server, :check)
  def continue(server), do: GenServer.call(server, :continue)

  @impl true
  def init(opts) do
    setup_opts = Keyword.get(opts, :setup_opts, [])
    {snapshot, error} = initial_status(Setup.status(setup_opts))

    {:ok,
     %{
       snapshot: snapshot,
       error: error,
       phase: :setup,
       task: nil,
       setup_opts: setup_opts,
       tasks: Keyword.fetch!(opts, :tasks),
       runtime_supervisor: Keyword.fetch!(opts, :runtime_supervisor),
       runtime: Keyword.get(opts, :runtime, Runtime),
       runtime_monitor: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:snapshot, :error, :phase]), state}
  end

  def handle_call(action, _from, %{task: task} = state)
      when action in [:check, :continue] and not is_nil(task),
      do: {:reply, {:error, :busy}, state}

  def handle_call(action, _from, %{phase: :ready} = state)
      when action in [:check, :continue], do: {:reply, {:error, :already_started}, state}

  def handle_call(:check, _from, state) do
    owner = self()
    opts = Keyword.put(state.setup_opts, :notify, owner)

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        with {:ok, _} <- Setup.new_run(opts), do: Setup.check_prerequisites(opts)
      end)

    {:reply, :ok, %{state | task: task, phase: :checking, error: nil}}
  end

  # The app runs on its own SQLite file, so nothing on the checklist is needed
  # to start it: the checklist is what developing a project needs, and the
  # agent can help with it once the app is up. Creating a project still waits
  # on it (`Setup.generate_project/3`).
  def handle_call(:continue, _from, state) do
    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        DynamicSupervisor.start_child(state.runtime_supervisor, {state.runtime, []})
      end)

    {:reply, :ok, %{state | task: task, phase: :starting, error: nil}}
  end

  @impl true
  def handle_info({:machine_setup, snapshot}, state),
    do: {:noreply, %{state | snapshot: snapshot}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, result |> completed(%{state | task: nil}) |> notify_settled()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, reason |> failed(%{state | task: nil}) |> notify_settled()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{runtime_monitor: ref} = state),
    do: {:noreply, failed(reason, %{state | runtime_monitor: nil})}

  defp completed({:ok, snapshot}, %{phase: :checking} = state),
    do: %{state | snapshot: snapshot, phase: :setup}

  defp completed({:ok, pid}, %{phase: :starting} = state) when is_pid(pid),
    do: %{state | phase: :ready, runtime_monitor: Process.monitor(pid)}

  defp completed({:error, reason}, state), do: failed(reason, state)

  defp failed(reason, state),
    do: %{state | phase: :setup, error: Exception.format_exit(reason)}

  defp notify_settled(state) do
    :telemetry.execute(
      [:code_my_spec_desktop, :bootstrap, :settled],
      %{system_time: System.system_time()},
      %{bootstrap: self(), status: Map.take(state, [:snapshot, :error, :phase])}
    )

    state
  end

  defp initial_status({:ok, snapshot}), do: {snapshot, nil}
  defp initial_status(:none), do: {nil, nil}
  defp initial_status({:error, reason}), do: {nil, inspect(reason)}
end
