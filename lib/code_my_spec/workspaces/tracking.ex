defmodule CodeMySpec.Workspaces.Tracking do
  @moduledoc """
  Records what a workspace did, from the code that did it.

  Deliberately not driven off the PubSub broadcasts: the boot watcher runs in
  its own task and can finish before any screen has subscribed, so a listener
  is not a reliable place to record a transition that happens exactly once.
  """

  alias CodeMySpec.{Analytics, Events}
  alias CodeMySpec.Workspaces.Workspace

  @spec boot_started(Workspace.t()) :: :ok
  def boot_started(%Workspace{} = workspace), do: record(:workspace_boot_started, workspace)

  @spec step(Workspace.t()) :: :ok
  def step(%Workspace{} = workspace), do: record(:workspace_step, workspace)

  @spec running(Workspace.t()) :: :ok
  def running(%Workspace{} = workspace), do: record(:workspace_running, workspace)

  @spec failed(Workspace.t()) :: :ok
  def failed(%Workspace{} = workspace) do
    record(:workspace_failed, workspace, %{error: workspace.error})
  end

  @doc """
  The visitor left while it was still coming up.

  Called by the surface, because only the surface knows they went away. A
  floor rather than an exact count — a browser that vanishes without a clean
  disconnect never reports — so treat a rise as real and a zero as unproven.
  """
  @spec abandoned(Workspace.t()) :: :ok
  def abandoned(%Workspace{status: :booting} = workspace), do: record(:workspace_abandoned, workspace)

  def abandoned(%Workspace{}), do: :ok

  defp record(name, %Workspace{} = workspace, extra \\ %{}) do
    data =
      Map.merge(
        %{
          project_id: workspace.project_id,
          step: workspace.step,
          waited_seconds: waited_seconds(workspace)
        },
        extra
      )

    Analytics.dispatch(name, data, :server)
    Events.record(name, data)
    :ok
  end

  # booted_at, not inserted_at — a retry gets its own clock rather than
  # inheriting the wait of every attempt before it.
  defp waited_seconds(%Workspace{booted_at: nil}), do: 0

  defp waited_seconds(%Workspace{booted_at: started}) do
    DateTime.diff(DateTime.utc_now(), started, :second)
  end
end
