defmodule CodeMySpec.Requirements.ProjectionTest do
  @moduledoc """
  Whether the rows carry the graph.

  This is the question that decides step 3. `requirement_graphs.payload` can be
  retired only if a graph read back from rows is the same graph that was
  computed — so these compare the two directly rather than asserting properties
  of either.

  A round trip that loses a node loses it silently: the reader returns a smaller
  graph, every query against it answers consistently, and the requirement that
  vanished simply stops being work anybody is told about. That is the failure
  this file exists to make loud.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.{Preloader, Projection, RequirementGraph}
  alias CodeMySpec.Stories

  setup do
    %{scope: full_scope_fixture()}
  end

  defp round_trip(scope) do
    {nodes, edges} = RequirementGraph.compute_graph(scope)
    {read_nodes, read_edges} = Projection.load(scope, Preloader.load(scope))

    {{nodes, edges}, {read_nodes, read_edges}}
  end

  defp keys(nodes),
    do: nodes |> Enum.map(&{&1.entity_type, &1.entity_id, &1.name}) |> MapSet.new()

  describe "load/2 against a computed graph" do
    test "every computed node comes back", %{scope: scope} do
      {{nodes, _}, {read, _}} = round_trip(scope)

      assert nodes != [], "a project with no nodes makes this vacuous"

      assert keys(read) == keys(nodes),
             "a node that does not survive the round trip stops being work anyone is " <>
               "told about, and every query against the smaller graph still agrees"
    end

    test "every computed edge comes back", %{scope: scope} do
      {{_, edges}, {_, read}} = round_trip(scope)

      assert MapSet.new(read) == MapSet.new(edges)
    end

    # The fields that are not stored. If rehydration drops one, the node is
    # still there and still keyed correctly — it just quietly loses the property
    # that decides how it is executed or displayed.
    test "definition fields rehydrate rather than coming back nil", %{scope: scope} do
      {{nodes, _}, {read, _}} = round_trip(scope)

      by_key = Map.new(read, &{{&1.entity_type, &1.entity_id, &1.name}, &1})

      for computed <- nodes do
        key = {computed.entity_type, computed.entity_id, computed.name}
        loaded = Map.fetch!(by_key, key)

        assert loaded.description == computed.description
        assert loaded.scope == computed.scope
        assert loaded.execution_type == computed.execution_type
        assert loaded.validation_type == computed.validation_type
        assert loaded.satisfied_by == computed.satisfied_by
        assert loaded.subagent_role == computed.subagent_role
      end
    end

    test "the verdict is the stored one, not a recomputed one", %{scope: scope} do
      {{nodes, _}, {read, _}} = round_trip(scope)

      computed_verdicts =
        Map.new(nodes, &{{&1.entity_type, &1.entity_id, &1.name}, &1.satisfied})

      for node <- read do
        key = {node.entity_type, node.entity_id, node.name}
        assert node.satisfied == Map.fetch!(computed_verdicts, key)
      end
    end
  end

  # The fixture project alone produces 13 project nodes and nothing else, so the
  # tests above exercise one of `entity_for/2`'s three branches. Component ids
  # are UUIDs and story ids are integers — the two easiest to get wrong were the
  # two not being run.
  describe "load/2 across all three entity types" do
    setup %{scope: scope} do
      component_fixture(scope, %{type: "context"})

      {:ok, story} =
        Stories.create_story(scope, %{title: "A story", description: "for story nodes"})

      {:ok, _} = Stories.update_story(scope, story, %{ready_for_dev: true})

      :ok
    end

    test "the graph carries all three, and all three round trip", %{scope: scope} do
      {{nodes, edges}, {read, read_edges}} = round_trip(scope)

      present = nodes |> Enum.map(& &1.entity_type) |> MapSet.new()

      assert MapSet.member?(present, "component"), "no component nodes — not covering them"
      assert MapSet.member?(present, "story"), "no story nodes — not covering them"
      assert MapSet.member?(present, "project")

      assert keys(read) == keys(nodes)
      assert MapSet.new(read_edges) == MapSet.new(edges)
    end

    test "a component node keeps its uuid and a story node its integer id", %{scope: scope} do
      {_computed, {read, _}} = round_trip(scope)

      component_node = Enum.find(read, &(&1.entity_type == "component"))
      story_node = Enum.find(read, &(&1.entity_type == "story"))

      assert is_binary(component_node.entity_id)
      assert is_integer(story_node.entity_id)
    end
  end

  # The question the payload could not answer, and the reason for all of this.
  # A `bytea` addressed by one hash cannot say which of its nodes a changed file
  # touches, so any change discarded the whole graph.
  describe "for_file/2" do
    setup %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      RequirementGraph.compute_graph(scope)
      %{component: component}
    end

    test "a component's file names that component's requirements", %{
      scope: scope,
      component: component
    } do
      path = "lib/demo/#{System.unique_integer([:positive])}.ex"

      Repo.insert!(%CodeMySpec.Files.File{
        project_id: scope.active_project_id,
        harness_id: scope.active_harness_id,
        component_id: component.id,
        path: path,
        role: :implementation
      })

      found = Projection.for_file(scope, path)

      assert found != []
      assert Enum.all?(found, &(&1.component_id == component.id))
    end

    # A pinned nil in `component_id == ^nil` compiles to `= NULL`, which is
    # never true — so a story's file must not accidentally match every node
    # whose component is null, which is every project node.
    test "a file owned by nothing bears on nothing", %{scope: scope} do
      path = "lib/demo/unowned_#{System.unique_integer([:positive])}.ex"

      Repo.insert!(%CodeMySpec.Files.File{
        project_id: scope.active_project_id,
        harness_id: scope.active_harness_id,
        path: path,
        role: :implementation
      })

      assert Projection.for_file(scope, path) == [],
             "an unowned file bearing on every project requirement would be worse " <>
               "than no answer — it would invalidate the whole graph on any edit"
    end

    test "a path with no file row is not an error", %{scope: scope} do
      assert Projection.for_file(scope, "lib/does/not/exist.ex") == []
    end
  end

  describe "load/2 when rows and definitions disagree" do
    # A row whose name matches no definition is dropped rather than guessed at:
    # the definitions moved and this node genuinely is not in the graph any
    # more. Rehydrating it would put a retired requirement back in front of an
    # agent.
    test "a row with no matching definition is not rehydrated", %{scope: scope} do
      RequirementGraph.compute_graph(scope)

      Repo.insert!(%CodeMySpec.Requirements.Node{
        project_id: scope.active_project_id,
        name: "a_requirement_that_no_longer_exists",
        description: "left behind by a definition rename",
        satisfied: true
      })

      {read, _edges} = Projection.load(scope, Preloader.load(scope))

      refute Enum.any?(read, &(&1.name == "a_requirement_that_no_longer_exists"))
    end
  end
end
