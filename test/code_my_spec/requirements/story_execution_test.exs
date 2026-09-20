defmodule CodeMySpec.Requirements.StoryExecutionTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.{Requirement, StoryExecution}

  @story_names ~w(component_linked three_amigos_complete bdd_specs_exist bdd_specs_passing code_on_running_copy qa_complete story_issues_resolved)

  defp fixture do
    story = %{
      id: 1,
      title: "Active",
      component_id: "surface",
      priority: 1,
      inserted_at: ~N[2026-01-01 00:00:00]
    }

    surface = %{id: "surface", parent_component_id: nil, dependencies: []}

    ctx = %{
      stories: [story],
      components: [surface],
      components_by_id: %{"surface" => surface},
      questions_by_story: %{}
    }

    nodes = Enum.map(@story_names, &node("story", 1, &1, true))
    {story, ctx, nodes}
  end

  defp unsatisfy(%{name: name} = node, name), do: %{node | satisfied: false}
  defp unsatisfy(node, _name), do: node

  defp node(type, id, name, satisfied) do
    %Requirement{
      entity_type: type,
      entity_id: id,
      entity_name: to_string(id),
      name: name,
      satisfied: satisfied,
      satisfied_by: CodeMySpec.AgentTasks.ComponentCode
    }
  end

  defp key(n), do: {n.entity_type, n.entity_id, n.name}

  test "missing projection is blocked even when every available node passes" do
    {story, ctx, [_ | nodes]} = fixture()
    result = StoryExecution.from_graph(story, nodes, [], ctx, nil)
    assert result.status == :blocked
    assert result.reason =~ "component_linked"
  end

  test "a satisfied intermediary preserves the external blocker" do
    {story, ctx, nodes} = fixture()
    external = node("story", 2, "bdd_specs_exist", false)
    middle = node("component", "surface", "implementation_file", true)
    target = Enum.find(nodes, &(&1.name == "bdd_specs_passing"))
    edges = [%{from: key(external), to: key(middle)}, %{from: key(middle), to: key(target)}]
    result = StoryExecution.from_graph(story, [external, middle | nodes], edges, ctx, nil)
    assert result.status == :blocked
    assert external in result.blockers
    assert result.actionable == []
  end

  test "waiting-story work and UAT do not prevent local completion" do
    {story, ctx, nodes} = fixture()
    waiting = node("story", 2, "bdd_specs_exist", false)
    deploy = node("story", 1, "deploy", false)
    result = StoryExecution.from_graph(story, [waiting, deploy | nodes], [], ctx, nil)
    assert result.status == :complete
    assert result.wave == []
  end

  test "an open question prevents an otherwise actionable task" do
    {story, ctx, nodes} = fixture()
    task = node("component", "surface", "implementation_file", false)
    ctx = %{ctx | questions_by_story: %{1 => [%{status: :open, text: "Which customer?"}]}}
    result = StoryExecution.from_graph(story, [task | nodes], [], ctx, :coding)
    assert result.status == :blocked
    assert result.reason =~ "Which customer?"
    assert result.actionable == []
  end

  test "role filtering cannot turn QA work into story completion" do
    {story, ctx, nodes} = fixture()
    nodes = Enum.map(nodes, &unsatisfy(&1, "qa_complete"))
    result = StoryExecution.from_graph(story, nodes, [], ctx, :coding)
    assert result.status == :blocked
    assert result.actionable == []
    assert Enum.any?(result.blockers, &(&1.name == "qa_complete"))
  end
end
