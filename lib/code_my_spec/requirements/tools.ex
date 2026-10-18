defmodule CodeMySpec.Requirements.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Files,
      CodeMySpec.Requirements,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Requirements.Tools.GetNextRequirement,
      CodeMySpec.Requirements.Tools.ListRequirements,
      CodeMySpec.Requirements.Tools.ShowComponentRequirements,
      CodeMySpec.Requirements.Tools.ShowRequirement,
      CodeMySpec.Requirements.Tools.ShowStoryRequirements,
      CodeMySpec.Requirements.Tools.SyncProject
    ]
  end
end
