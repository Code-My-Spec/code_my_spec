defmodule CodeMySpec.Requirements.StoryExecutionTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.{Requirement, StoryExecution}

  @story_names ~w(component_linked three_amigos_complete questions_answered bdd_specs_exist ready_for_qa story_promoted qa_complete story_issues_resolved story_issues_triaged)

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
    target = Enum.find(nodes, &(&1.name == "ready_for_qa"))
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

  # 56cf5697: a sealed story's post-seal open questions used to block every
  # role including product, the one role that owns questions — so nothing
  # was ever offered the work of clearing them. `questions_answered` is the
  # node that names product as the actor; `role != :product` is what lets it
  # through to be offered instead of hitting the blanket block below.
  test "a sealed story's open questions are offered to product, not blocked" do
    {story, ctx, nodes} = fixture()
    ctx = %{ctx | questions_by_story: %{1 => [%{status: :open, text: "Which customer?"}]}}
    nodes = Enum.map(nodes, &unsatisfy(&1, "questions_answered"))

    result = StoryExecution.from_graph(story, nodes, [], ctx, :product)

    assert result.status == :ready
    assert Enum.any?(result.actionable, &(&1.name == "questions_answered"))
  end

  test "the same open question still blocks every other role" do
    {story, ctx, nodes} = fixture()
    ctx = %{ctx | questions_by_story: %{1 => [%{status: :open, text: "Which customer?"}]}}
    nodes = Enum.map(nodes, &unsatisfy(&1, "questions_answered"))

    for role <- [:coding, :qa, nil] do
      result = StoryExecution.from_graph(story, nodes, [], ctx, role)
      assert result.status == :blocked, "expected #{inspect(role)} to stay blocked"
      assert result.reason =~ "Which customer?"
    end
  end

  test "role filtering cannot turn QA work into story completion" do
    {story, ctx, nodes} = fixture()
    nodes = Enum.map(nodes, &unsatisfy(&1, "qa_complete"))
    result = StoryExecution.from_graph(story, nodes, [], ctx, :coding)
    assert result.status == :blocked
    assert result.actionable == []
    assert Enum.any?(result.blockers, &(&1.name == "qa_complete"))
  end

  # 4292518a, strict and unclamped: a bound read is held by its own story and
  # surface subtree, not by another story's work reached through a kickoff
  # edge. Story 1084's coder read "blocked" on other stories' bdd_specs_exist.
  describe "a bound read" do
    defp bound(ctx), do: Map.put(ctx, :seeds, :local)

    test "another story's unmet node does not hold the bound story" do
      {story, ctx, nodes} = fixture()
      external = node("story", 2, "bdd_specs_exist", false)
      nodes = Enum.map(nodes, &unsatisfy(&1, "ready_for_qa"))
      target = Enum.find(nodes, &(&1.name == "ready_for_qa"))
      edges = [%{from: key(external), to: key(target)}]

      result = StoryExecution.from_graph(story, [external | nodes], edges, bound(ctx), :coding)

      assert target in result.actionable,
             "the bound story was held by story 2's bdd_specs_exist: #{inspect(result.reason)}"

      refute external in result.blockers
    end

    test "the story's own ordering still holds" do
      {story, ctx, nodes} = fixture()

      nodes =
        nodes
        |> Enum.map(&(&1 |> unsatisfy("bdd_specs_exist") |> unsatisfy("ready_for_qa")))

      exist = Enum.find(nodes, &(&1.name == "bdd_specs_exist"))
      passing = Enum.find(nodes, &(&1.name == "ready_for_qa"))
      edges = [%{from: key(exist), to: key(passing)}]

      result = StoryExecution.from_graph(story, nodes, edges, bound(ctx), :coding)

      refute passing in result.actionable
    end

    test "an unbound read is still held by the other story" do
      {story, ctx, nodes} = fixture()
      external = node("story", 2, "bdd_specs_exist", false)
      nodes = Enum.map(nodes, &unsatisfy(&1, "ready_for_qa"))
      target = Enum.find(nodes, &(&1.name == "ready_for_qa"))
      edges = [%{from: key(external), to: key(target)}]

      result = StoryExecution.from_graph(story, [external | nodes], edges, ctx, :coding)

      refute target in result.actionable
    end
  end
end
