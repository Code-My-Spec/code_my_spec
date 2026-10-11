defmodule CodeMySpec.AgentTasks.FixStoryIssuesPromptTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.FixStoryIssues

  # 8a186121
  test "tells a coder how to get an obsolete criterion retired" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    issue_fixture(scope, %{status: :accepted, severity: :high, story_id: story.id})

    assert {:ok, prompt} = FixStoryIssues.command(scope, %{story_id: story.id})
    assert prompt =~ "If a criterion is obsolete or wrong, don't delete its spec"
    assert prompt =~ "(`create_issue`)"
  end
end
