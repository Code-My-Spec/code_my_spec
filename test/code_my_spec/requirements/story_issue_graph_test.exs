defmodule CodeMySpec.Requirements.StoryIssueGraphTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Requirements.StoryIssueGraph

  test "an unset persisted threshold uses the medium default and connects blocking submissions" do
    story = %{id: 601, title: "Email registration"}
    high = issue("high", :high)
    low = issue("low", :low)
    ctx = %{story_issues: [high, low]}
    config = %ProjectConfiguration{fix_issues_min_severity: nil}

    assert StoryIssueGraph.issues(story, ctx, config) == [high]

    assert [%{entity_id: "high", name: "submitted", satisfied: false}] =
             StoryIssueGraph.nodes(story, ctx, config)

    assert StoryIssueGraph.edges(story, ctx, config) == [
             %{from: {"story", 601, "story_issues_triaged"}, to: {"issue", "high", "submitted"}},
             %{from: {"issue", "high", "submitted"}, to: {"story", 601, "ready_for_qa"}}
           ]
  end

  test "an explicit severity threshold is respected" do
    story = %{id: 601, title: "Email registration"}
    high = issue("high", :high)
    low = issue("low", :low)
    ctx = %{story_issues: [high, low]}

    assert StoryIssueGraph.issues(story, ctx, %ProjectConfiguration{fix_issues_min_severity: :low}) ==
             [high, low]

    assert StoryIssueGraph.issues(story, ctx, %ProjectConfiguration{
             fix_issues_min_severity: :critical
           }) ==
             []
  end

  defp issue(id, severity),
    do: %Issue{
      id: id,
      title: id,
      story_id: 601,
      status: :accepted,
      severity: severity,
      scope: :app
    }
end
