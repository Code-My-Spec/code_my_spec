defmodule CodeMySpec.AgentTasks.TriageIssuesTest do
  @moduledoc """
  e90a1f80: the story-scope prompt told the agent to discover issues with
  `list_issues(status: "incoming", story_number: N)`, no severity named —
  which, under the severity default in place when this was reported, silently
  dropped lows that `evaluate/2` (any severity) still graded on. Product
  decision 006f1c97 (story 709) later removed that default entirely, so the
  reported symptom no longer reproduces; these lock the agreement explicitly
  rather than resting on an implicit default that could drift again.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.AgentTasks.TriageIssues
  alias CodeMySpec.Issues
  alias CodeMySpec.ToolLibrary

  describe "command/2 — story scope" do
    test "names severity explicitly, agreeing with what evaluate/2 grades" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      low = issue_fixture(scope, %{severity: :low, scope: :app})
      assert 1 = Issues.attribute_to_story(scope, [low.id], story.id)
      task = %{story_id: story.id, state: %{}}

      assert {:ok, prompt} = TriageIssues.command(scope, task)
      assert prompt =~ ~s(severity: "all")
    end
  end

  describe "the story-scope prompt's prescribed list_issues call" do
    test "returns an incoming low linked to that story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      low = issue_fixture(scope, %{severity: :low, scope: :app})
      assert 1 = Issues.attribute_to_story(scope, [low.id], story.id)

      assert {:ok, result} =
               ToolLibrary.data(
                 "list_issues",
                 %{status: "incoming", story_number: story.number, severity: "all"},
                 %{scope: scope}
               )

      assert Enum.any?(result["issues"], &(&1["id"] == low.id))
    end

    test "agrees with evaluate/2: once triaged there, evaluate/2 sees it resolved too" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      low = issue_fixture(scope, %{severity: :low, scope: :app})
      assert 1 = Issues.attribute_to_story(scope, [low.id], story.id)
      task = %{story_id: story.id, state: %{}}

      assert {:ok, :invalid, feedback} = TriageIssues.evaluate(scope, task)
      assert feedback =~ "on story #{story.number}, at any severity"

      issue = Issues.get_issue(scope, low.id)
      {:ok, _} = Issues.dismiss_issue(scope, issue, "fixture cleanup")

      assert {:ok, :valid} = TriageIssues.evaluate(scope, task)
    end
  end
end
