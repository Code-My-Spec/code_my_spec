defmodule CodeMySpec.Bootstrap.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    exports: [Content],
    deps: [
      CodeMySpec.Auth,
      CodeMySpec.ExecutionContexts,
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.PublicUrl,
      CodeMySpec.Repo,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Bootstrap.Tools.InitProject,
      CodeMySpec.Bootstrap.Tools.InstallAgentsMd,
      CodeMySpec.Bootstrap.Tools.InstallClaudeMd,
      CodeMySpec.Bootstrap.Tools.InstallCredoChecks,
      CodeMySpec.Bootstrap.Tools.InstallRules,
      CodeMySpec.Bootstrap.Tools.ListProjects
    ]
  end
end
