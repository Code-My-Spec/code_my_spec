defmodule CodeMySpec.Requirements.ProjectIssueGraphTest do
  use ExUnit.Case, async: true
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Requirements.{GraphProjector, ProjectIssueGraph, Requirement, Topology}

  defp node(type, id, name, satisfied \\ false) do
    %Requirement{
      entity_type: type,
      entity_id: id,
      name: name,
      entity_name: "Example",
      satisfied: satisfied
    }
  end

  defp base(setup_satisfied \\ true) do
    setup = node("project", "p", "qa_setup", setup_satisfied)
    aggregate = node("project", "p", "issues_resolved")
    story = node("story", 1, "component_linked")
    journey = node("project", "p", "qa_journey_plan")

    %{
      nodes: [setup, aggregate, story, journey],
      actionable: [story, aggregate],
      edges: [
        edge(setup, story),
        edge(story, journey),
        edge(aggregate, journey),
        edge(setup, aggregate)
      ]
    }
  end

  defp edge(a, b), do: %{from: Topology.node_key(a), to: Topology.node_key(b)}

  defp issue(id, attrs \\ []),
    do:
      struct!(
        Issue,
        Keyword.merge(
          [
            id: id,
            title: "Fix #{id}",
            status: :accepted,
            severity: :high
          ],
          attrs
        )
      )

  defp keys(nodes), do: MapSet.new(nodes, &Topology.node_key/1)

  test "independent issue branches fan out beside stories and join only the issue aggregate" do
    graph =
      ProjectIssueGraph.project(base(), "p", [
        issue("a"),
        issue("b", assigned_working_copy_id: "copy", awaiting_role: :qa)
      ])

    assert %{from: {"project", "p", "qa_setup"}, to: {"issue", "a", "assigned"}} in graph.edges
    assert %{from: {"issue", "a", "assigned"}, to: {"issue", "a", "submitted"}} in graph.edges
    assert %{from: {"issue", "a", "submitted"}, to: {"issue", "a", "completed"}} in graph.edges

    assert %{from: {"issue", "a", "completed"}, to: {"project", "p", "issues_resolved"}} in graph.edges

    actionable = keys(graph.actionable)
    assert MapSet.member?(actionable, {"issue", "a", "assigned"})
    assert MapSet.member?(actionable, {"issue", "b", "completed"})
    assert MapSet.member?(actionable, {"story", 1, "component_linked"})
    refute MapSet.member?(actionable, {"project", "p", "issues_resolved"})
    refute Enum.any?(graph.edges, &match?(%{from: {"story", _, _}, to: {"issue", _, _}}, &1))
  end

  test "QA setup blocks unsubmitted issue work without a global assignment barrier" do
    graph = ProjectIssueGraph.project(base(false), "p", [issue("a")])
    assert graph.actionable == []
  end

  test "submission follows recorded handoff and failed QA reopens coding" do
    for {stage, expected} <- [{:coding, "submitted"}, {:qa, "completed"}, {:promote, "completed"}] do
      graph =
        ProjectIssueGraph.project(base(), "p", [
          issue("a", assigned_working_copy_id: "copy", awaiting_role: stage)
        ])

      assert Enum.filter(graph.actionable, &(&1.entity_type == "issue")) |> Enum.map(& &1.name) ==
               [expected]
    end
  end

  test "story issues and terminal issues leave no project branch and no aggregate coder task" do
    graph =
      ProjectIssueGraph.project(base(), "p", [
        issue("story", story_id: 1),
        issue("done", status: :resolved),
        issue("dismissed", status: :dismissed)
      ])

    refute Enum.any?(graph.nodes, &(&1.entity_type == "issue"))
    aggregate = Enum.find(graph.nodes, &(&1.name == "issues_resolved"))
    assert aggregate.satisfied
    assert is_nil(aggregate.satisfied_by)
  end

  test "sigma renders every issue stage beside the story with complete downward edges" do
    graph = ProjectIssueGraph.project(base(), "p", [issue("a"), issue("b")])
    sigma = GraphProjector.project_layout(graph, [])
    issues = Enum.filter(sigma.nodes, &(&1.attributes.entity_type == "issue"))
    assert length(issues) == 6
    positions = Map.new(sigma.nodes, &{&1.key, &1.attributes})

    assert Enum.all?(
             sigma.edges,
             &(Map.has_key?(positions, &1.source) and Map.has_key?(positions, &1.target))
           )

    assert Enum.all?(sigma.edges, &(positions[&1.source].y > positions[&1.target].y))
    assert length(Enum.uniq_by(issues, &{&1.attributes.x, &1.attributes.y})) == 6
    story_x = Enum.find(sigma.nodes, &(&1.attributes.entity_type == "story")).attributes.x
    assert Enum.all?(issues, &(&1.attributes.x > story_x))
  end
end
