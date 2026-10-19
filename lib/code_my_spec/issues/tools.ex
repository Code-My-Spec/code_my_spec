defmodule CodeMySpec.Issues.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Configurations,
      CodeMySpec.Issues,
      CodeMySpec.Stories,
      CodeMySpec.TaskOwner,
      CodeMySpec.Tools,
      CodeMySpec.Utils
    ]

  def all do
    [
      CodeMySpec.Issues.Tools.AcceptIssue,
      CodeMySpec.Issues.Tools.AssignIssueToWorkingCopy,
      CodeMySpec.Issues.Tools.CreateIssue,
      CodeMySpec.Issues.Tools.DismissIssue,
      CodeMySpec.Issues.Tools.GetIssue,
      CodeMySpec.Issues.Tools.ListIssues,
      CodeMySpec.Issues.Tools.ResolveIssue,
      CodeMySpec.Issues.Tools.SetActiveIssue,
      CodeMySpec.Issues.Tools.SubmitStoryIssue,
      CodeMySpec.Issues.Tools.UnassignIssue,
      CodeMySpec.Issues.Tools.UnassignIssueFromWorkingCopy,
      CodeMySpec.Issues.Tools.UpdateIssue
    ]
  end
end
