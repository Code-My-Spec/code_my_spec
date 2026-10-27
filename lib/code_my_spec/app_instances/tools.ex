defmodule CodeMySpec.AppInstances.Tools do
  @moduledoc "Agent tools for app lifecycle and preview access."

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.CopyTools,
      CodeMySpec.Environments,
      CodeMySpec.AppInstances,
      CodeMySpec.CodeMode,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Workspaces
    ]

  def all do
    [
      CodeMySpec.AppInstances.Tools.ListAppInstances,
      CodeMySpec.AppInstances.Tools.GetAppInstance,
      CodeMySpec.AppInstances.Tools.EnsureAppRunning,
      CodeMySpec.AppInstances.Tools.RestartApp,
      CodeMySpec.AppInstances.Tools.ShareCopyApp,
      CodeMySpec.AppInstances.Tools.StopApp,
      CodeMySpec.AppInstances.Tools.UnshareCopyApp
    ]
  end
end
