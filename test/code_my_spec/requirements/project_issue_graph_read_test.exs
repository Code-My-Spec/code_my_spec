defmodule CodeMySpec.Requirements.ProjectIssueGraphReadTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures
  alias CodeMySpec.Requirements.{ProjectIssueGraph, Requirement}

  test "reads only accepted project issues at the configured blocking severity" do
    scope = full_scope_fixture()

    included =
      issue_fixture(scope, %{
        title: "Blocking project issue",
        severity: :critical,
        status: :accepted
      })

    issue_fixture(scope, %{title: "Below threshold", severity: :info, status: :accepted})
    issue_fixture(scope, %{title: "Not triaged", severity: :critical, status: :incoming})
    story = CodeMySpec.StoriesFixtures.story_fixture(scope)

    issue_fixture(scope, %{
      title: "Story issue",
      severity: :critical,
      status: :accepted,
      story_id: story.id
    })

    nodes =
      for name <- ["qa_setup", "issues_resolved"],
          do: %Requirement{
            entity_type: "project",
            entity_id: scope.active_project_id,
            name: name,
            satisfied: true
          }

    graph = ProjectIssueGraph.read(scope, %{nodes: nodes, edges: [], actionable: []})
    issue_nodes = Enum.filter(graph.nodes, &(&1.entity_type == "issue"))
    assert length(issue_nodes) == 3
    assert Enum.all?(issue_nodes, &(&1.entity_id == included.id))
  end
end
