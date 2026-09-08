defmodule CodeMySpec.Workspaces.Boot do
  @moduledoc """
  Watches an instance come up, and decides when it hasn't.

  Booting is slow — the container fetches deps, creates the database and
  compiles before the app answers — so the visitor's screen cannot block on it.
  This runs as a supervised task and reports the outcome by broadcast.
  """

  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.{BootSteps, Runner, Workspace}

  @poll_interval 2_000
  @timeout 15 * 60 * 1_000

  @spec watch(Workspace.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def watch(%Workspace{} = workspace) do
    poll(workspace, deadline())
  end

  defp deadline, do: System.monotonic_time(:millisecond) + timeout()

  # Reloaded every pass: a project deleted mid-boot takes its workspace with
  # it, and there is then nothing left to report to.
  defp poll(%Workspace{} = workspace, deadline) do
    case Workspaces.reload(workspace) do
      nil -> {:ok, workspace}
      current -> check(current, deadline)
    end
  end

  defp check(%Workspace{} = workspace, deadline) do
    workspace = record_progress(workspace)

    if Runner.healthy?(workspace.port),
      do: Workspaces.mark_running(workspace),
      else: keep_waiting(workspace, deadline)
  end

  # Only writes when the phase actually moved on, so a slow phase doesn't
  # generate a broadcast every couple of seconds.
  defp record_progress(%Workspace{} = workspace) do
    workspace.container_name
    |> Runner.logs()
    |> BootSteps.furthest()
    |> advance(workspace)
  end

  defp advance(step, %Workspace{step: step} = workspace), do: workspace
  defp advance(nil, %Workspace{} = workspace), do: workspace

  defp advance(step, %Workspace{} = workspace) do
    {:ok, workspace} = Workspaces.mark_step(workspace, step)
    workspace
  end

  defp keep_waiting(%Workspace{} = workspace, deadline) do
    with :alive <- container_state(workspace),
         :waiting <- time_left(deadline) do
      Process.sleep(poll_interval())
      poll(workspace, deadline)
    else
      :dead ->
        Workspaces.mark_failed(workspace, "The workspace stopped before it finished starting up.")

      :expired ->
        Workspaces.mark_failed(workspace, "The workspace took too long to start.")
    end
  end

  defp container_state(%Workspace{container_name: name}) do
    if Runner.alive?(name), do: :alive, else: :dead
  end

  defp time_left(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :waiting, else: :expired
  end

  defp timeout, do: config(:boot_timeout, @timeout)
  defp poll_interval, do: config(:poll_interval, @poll_interval)

  defp config(key, default) do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(key, default)
  end
end
