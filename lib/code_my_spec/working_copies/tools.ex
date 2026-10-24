defmodule CodeMySpec.WorkingCopies.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.AppInstances,
      CodeMySpec.CodeMode,
      CodeMySpec.Promotion,
      CodeMySpec.Staffing,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Workspaces
    ]

  def all do
    [
      CodeMySpec.WorkingCopies.Tools.CreateWorkingCopy,
      CodeMySpec.WorkingCopies.Tools.ListWorkingCopies,
      CodeMySpec.WorkingCopies.Tools.OffboardWorkingCopy,
      CodeMySpec.WorkingCopies.Tools.SetWorkingCopyLoop,
      CodeMySpec.WorkingCopies.Tools.SyncWorkingCopy
    ]
  end
end
