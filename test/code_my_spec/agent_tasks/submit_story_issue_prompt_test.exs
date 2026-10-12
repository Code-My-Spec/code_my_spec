defmodule CodeMySpec.AgentTasks.SubmitStoryIssuePromptTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.SubmitStoryIssue

  # 8a186121
  test "tells a coder how to get an obsolete criterion retired" do
    scope = working_copy_scope_fixture()
    story = story_fixture(scope)
    issue = issue_fixture(scope, %{status: :accepted, severity: :high, story_id: story.id})

    assert {:ok, prompt} =
             SubmitStoryIssue.command(scope, %{id: Ecto.UUID.generate(), issue_id: issue.id})

    assert prompt =~ "If a criterion is obsolete or wrong, don't delete its spec"
    assert prompt =~ "(`create_issue`)"
  end
end
