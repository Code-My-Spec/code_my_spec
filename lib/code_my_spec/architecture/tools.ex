defmodule CodeMySpec.Architecture.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AgentTasks,
      CodeMySpec.Architecture,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Environments,
      CodeMySpec.LocalScope,
      CodeMySpec.Paths,
      CodeMySpec.Stories,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Architecture.Tools.AnalyzeStories,
      CodeMySpec.Architecture.Tools.CheckArchitecture,
      CodeMySpec.Architecture.Tools.CheckDecisions,
      CodeMySpec.Architecture.Tools.ExecuteProposal,
      CodeMySpec.Architecture.Tools.RegenerateProposal,
      CodeMySpec.Architecture.Tools.ShowArchitectureOverview,
      CodeMySpec.Architecture.Tools.ShowNamespaceHierarchy,
      CodeMySpec.Architecture.Tools.ValidateDependencyGraph
    ]
  end
end
