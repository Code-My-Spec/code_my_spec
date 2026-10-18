defmodule CodeMySpec.Components.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    exports: [CreateComponent],
    deps: [
      CodeMySpec.Architecture,
      CodeMySpec.Components,
      CodeMySpec.Files,
      CodeMySpec.Stories,
      CodeMySpec.Tools
    ]

  def all do
    [
      CodeMySpec.Components.Tools.AddDependency,
      CodeMySpec.Components.Tools.ArchitectureHealthSummary,
      CodeMySpec.Components.Tools.ContextStatistics,
      CodeMySpec.Components.Tools.CreateComponent,
      CodeMySpec.Components.Tools.DeleteComponent,
      CodeMySpec.Components.Tools.GetComponent,
      CodeMySpec.Components.Tools.ListComponents,
      CodeMySpec.Components.Tools.OrphanedContexts,
      CodeMySpec.Components.Tools.RemoveDependency,
      CodeMySpec.Components.Tools.ReviewContextDesign,
      CodeMySpec.Components.Tools.ShowArchitecture,
      CodeMySpec.Components.Tools.StartContextDesign,
      CodeMySpec.Components.Tools.UpdateComponent
    ]
  end
end
