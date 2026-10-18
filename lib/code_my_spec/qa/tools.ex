defmodule CodeMySpec.Qa.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.CodeMode,
      CodeMySpec.Projects,
      CodeMySpec.Qa,
      CodeMySpec.Stories,
      CodeMySpec.Tools,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Qa.Tools.CallMcpServer,
      CodeMySpec.Qa.Tools.GetLocalAppToken,
      CodeMySpec.Qa.Tools.InvalidateQaAttempt,
      CodeMySpec.Qa.Tools.ListQaAttempts,
      CodeMySpec.Qa.Tools.SubmitIssueQaResult,
      CodeMySpec.Qa.Tools.SubmitQaResult
    ]
  end
end
