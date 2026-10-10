defmodule CodeMySpecWeb.WorkingCopyLive.StoryGraphTest do
  use ExUnit.Case, async: true
  require Phoenix.LiveViewTest

  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpecWeb.WorkingCopyLive.StoryGraph

  test "keeps the story and component prerequisites, with external gates as boundaries" do
    story = node("story", 1, "ready")
    component = node("component", "a", "implemented")
    gate = node("project", "p", "setup", true)
    external = node("story", 2, "ready")
    unrelated = node("story", 3, "ready")
    external_parent = node("component", "b", "implemented")

    graph = %{
      nodes: [story, component, gate, external, unrelated, external_parent],
      actionable: [component],
      edges: [
        edge(component, story),
        edge(gate, component),
        edge(external, story),
        edge(external_parent, external)
      ]
    }

    flow = build(graph, 1, MapSet.new(["a"]))
    assert map_size(flow.nodes) == 3
    assert map_size(flow.edges) == 2
    assert flow.nodes["component-a-implemented"].data.status == "Actionable"
    assert flow.nodes["project-p-setup"].data.status == "Satisfied"
    refute Map.has_key?(flow.nodes, "story-2-ready")
    refute Map.has_key?(flow.nodes, "story-3-ready")
    refute Map.has_key?(flow.nodes, "component-b-implemented")

    assert Enum.all?(flow.nodes, fn {_, node} ->
             not node.draggable and not node.deletable and not node.connectable
           end)
  end

  test "status updates preserve positions and viewport, and traversal terminates on a cycle" do
    a = node("story", 1, "a")
    b = node("story", 1, "b")
    graph = %{nodes: [a, b], actionable: [], edges: [edge(a, b), edge(b, a)]}

    previous =
      graph
      |> build(1)
      |> LiveFlow.State.update_viewport(%{"x" => 25, "y" => 35, "zoom" => 0.8})

    previous = put_in(previous.nodes["story-1-a"].position, %{x: 480, y: 120})

    updated =
      %{graph | nodes: [%{a | satisfied: true}, b]}
      |> build(1)
      |> StoryGraph.preserve_view(previous)

    assert updated.nodes["story-1-a"].data.status == "Satisfied"
    assert updated.nodes["story-1-a"].position == %{x: 480, y: 120}
    assert updated.viewport == previous.viewport
  end

  test "includes all development requirements of member components, even without a path into a story node" do
    story = node("story", 1, "qa_complete")
    implementation = node("component", "surface", "implementation_file")
    tests = node("component", "child", "tests_passing")
    unrelated = node("component", "other", "implementation_file")

    graph = %{
      nodes: [story, implementation, tests, unrelated],
      actionable: [implementation],
      edges: []
    }

    flow = build(graph, 1, MapSet.new(["surface", "child"]))
    assert map_size(flow.nodes) == 3
    assert flow.nodes["component-surface-implementation_file"].data.status == "Actionable"
    assert Map.has_key?(flow.nodes, "component-child-tests_passing")
    refute Map.has_key?(flow.nodes, "component-other-implementation_file")
  end

  test "uses agent eligibility instead of the project frontier and marks each agent's next work" do
    resolve = node("story", 1, "story_issues_resolved")
    qa = node("story", 1, "qa_complete")
    coder = %{id: "coder", role: :coding}

    graph = %{
      nodes: [resolve, qa],
      actionable: [qa],
      edges: [],
      story_keys:
        MapSet.new([{"story", 1, "story_issues_resolved"}, {"story", 1, "qa_complete"}]),
      components: [],
      owners: []
    }

    flow = StoryGraph.build(graph, [{coder, %{actionable: [resolve]}}])
    assert flow.nodes["story-1-story_issues_resolved"].data.status == "Actionable"
    assert flow.nodes["story-1-story_issues_resolved"].data.next_agents == [coder]

    html =
      Phoenix.LiveViewTest.render_component(
        &CodeMySpecWeb.WorkingCopyLive.Components.StoryGraph.requirement/1,
        node: flow.nodes["story-1-story_issues_resolved"]
      )

    assert html =~ CodeMySpecWeb.WorkingCopyLive.Components.Agent.color(coder.id)
    assert html =~ "data-next-agent-ids=\"coder\""
    assert flow.nodes["story-1-qa_complete"].data.status == "Blocked"
    assert flow.nodes["story-1-qa_complete"].data.next_agents == []
  end

  test "warning follows the pending decision's task, not the agent's other requirements" do
    resolve = node("story", 1, "story_issues_resolved")
    qa = node("story", 1, "qa_complete")

    graph = %{
      nodes: [resolve, qa],
      actionable: [],
      edges: [],
      story_keys: MapSet.new(),
      components: [],
      owners: []
    }

    task = %{id: "task", requirement_name: resolve.name, story_id: 1}
    question = %{id: "q", task_id: "task", status: "pending"}
    answered = %{id: "answered", task_id: "task", status: "answered"}
    unbound = %{id: "unbound", task_id: nil, status: "pending"}
    tap_out = %{id: "tap", task_id: "task", status: "pending"}

    team = %{
      agent: %{tasks: [task]},
      questions: [question, answered, unbound],
      tap_outs: [tap_out]
    }

    flow = StoryGraph.build(graph, [], [team])
    assert flow.nodes["story-1-story_issues_resolved"].data.warnings == [question, tap_out]
    assert flow.nodes["story-1-qa_complete"].data.warnings == []
    selected = flow.nodes["story-1-story_issues_resolved"]
    other_team = %{agent: %{tasks: []}, questions: [unbound], tap_outs: []}
    assert [filtered] = StoryGraph.filter_teams([team, other_team], selected)
    assert filtered.questions == [question]
    assert filtered.tap_outs == [tap_out]
    assert StoryGraph.filter_teams([team], flow.nodes["story-1-qa_complete"]) == []
    assert StoryGraph.filter_teams([team, other_team], nil) == [team, other_team]

    html =
      Phoenix.LiveViewTest.render_component(
        &CodeMySpecWeb.WorkingCopyLive.Components.StoryGraph.requirement/1,
        node: flow.nodes["story-1-story_issues_resolved"]
      )

    assert html =~ "requirement-warning"
    assert html =~ "Pending question or tap-out"
  end

  defp build(graph, story_id, component_ids \\ MapSet.new(), components \\ []) do
    graph
    |> CodeMySpec.Requirements.StoryGraph.select(story_id, component_ids)
    |> Map.merge(%{components: components, owners: []})
    |> StoryGraph.build()
  end

  defp node(type, id, name, satisfied \\ false),
    do: %Requirement{entity_type: type, entity_id: id, name: name, satisfied: satisfied}

  defp edge(a, b),
    do: %{from: {a.entity_type, a.entity_id, a.name}, to: {b.entity_type, b.entity_id, b.name}}

  test "groups nested members, keeps story scope, and collapses edges between contexts" do
    a = node("component", "a", "implementation", true)
    b = node("component", "b", "tests")
    c = node("component", "c", "implementation")
    unrelated = node("component", "other", "tests")
    standalone = node("component", "solo", "implementation")
    story = node("story", 1, "ready")

    components = [
      component("users", "context"),
      component("a", "schema", "users"),
      component("b", "repository", "a"),
      component("other", "schema", "users"),
      component("billing", "context"),
      component("c", "schema", "billing"),
      component("solo", "schema")
    ]

    graph = %{
      nodes: [a, b, c, unrelated, standalone, story],
      actionable: [b],
      edges: [edge(a, b), edge(a, c), edge(b, c), edge(c, story)]
    }

    flow = build(graph, 1, MapSet.new(["a", "b", "c", "solo"]), components)
    assert map_size(flow.nodes) == 4
    assert flow.nodes["context-users"].data.counts == %{"Satisfied" => 1, "Actionable" => 1}
    assert length(flow.nodes["context-users"].data.requirements) == 2
    assert Map.has_key?(flow.nodes, "context-solo")
    assert Map.has_key?(flow.nodes, "story-1-ready")
    assert map_size(flow.edges) == 2
    assert Enum.all?(flow.edges, fn {_, edge} -> edge.source != edge.target end)
    assert flow.edges["context-users--context-billing"]
  end

  defp component(id, type, parent \\ nil),
    do: %{id: id, type: type, parent_component_id: parent, module_name: id}
end
