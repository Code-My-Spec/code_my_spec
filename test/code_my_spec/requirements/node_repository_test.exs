defmodule CodeMySpec.Requirements.NodeRepositoryTest do
  @moduledoc """
  Computed nodes becoming rows, and keeping their ids.

  This exists so edges have something to point at. `requirement_edges` will
  reference `requirements.id`, which is only meaningful if a node's id survives
  recomputation — and the graph is recomputed on every stop hook. Delete-and-
  reinsert would issue fresh ids each pass and orphan every edge, silently: the
  edges would still be rows, just pointing at nodes that no longer exist.

  So the assertion that carries the design is `ids stay the same`. The rest is
  identity: three entity types, three partial unique indexes, one owner each.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.{Node, NodeRepository, Requirement}

  setup do
    %{scope: full_scope_fixture()}
  end

  defp node(entity_type, entity_id, name, satisfied \\ false) do
    %Requirement{
      entity_type: entity_type,
      entity_id: entity_id,
      name: name,
      description: "#{name} on #{entity_type}",
      satisfied: satisfied,
      details: %{}
    }
  end

  describe "upsert_all/2" do
    test "a project node becomes a row keyed by its node_key", %{scope: scope} do
      project_id = scope.active_project_id

      keys = NodeRepository.upsert_all(scope, [node("project", project_id, "stories_exist")])

      assert %{{"project", ^project_id, "stories_exist"} => id} = keys
      assert is_integer(id)

      row = Repo.get(Node, id)
      assert row.project_id == project_id
      assert row.component_id == nil
      assert row.story_id == nil
    end

    # The property edges depend on. Recomputing must not renumber the graph.
    test "ids stay the same across a recomputation", %{scope: scope} do
      project_id = scope.active_project_id
      nodes = [node("project", project_id, "stories_exist")]

      first = NodeRepository.upsert_all(scope, nodes)
      second = NodeRepository.upsert_all(scope, nodes)

      assert first == second,
             "a node's id is what an edge points at — renumbering on recompute would " <>
               "leave every edge referencing a node that no longer exists"
    end

    test "recomputation moves the verdict without moving the row", %{scope: scope} do
      project_id = scope.active_project_id

      %{{"project", ^project_id, "stories_exist"} => id} =
        NodeRepository.upsert_all(scope, [node("project", project_id, "stories_exist", false)])

      refute Repo.get(Node, id).satisfied

      NodeRepository.upsert_all(scope, [node("project", project_id, "stories_exist", true)])

      assert Repo.get(Node, id).satisfied
      assert Repo.aggregate(Node, :count) == 1
    end

    test "two names on one project are two rows", %{scope: scope} do
      project_id = scope.active_project_id

      keys =
        NodeRepository.upsert_all(scope, [
          node("project", project_id, "stories_exist"),
          node("project", project_id, "personas_complete")
        ])

      assert map_size(keys) == 2
      assert Repo.aggregate(Node, :count) == 2
    end

    test "an empty list writes nothing", %{scope: scope} do
      assert NodeRepository.upsert_all(scope, []) == %{}
      assert Repo.aggregate(Node, :count) == 0
    end
  end

  describe "the changeset guards identity" do
    test "a node with no owner is refused" do
      changeset = Node.changeset(%Node{}, %{name: "orphan", description: "no owner"})

      refute changeset.valid?
    end

    test "a node with two owners is refused", %{scope: scope} do
      changeset =
        Node.changeset(%Node{}, %{
          name: "ambiguous",
          description: "two owners",
          project_id: scope.active_project_id,
          story_id: 1
        })

      refute changeset.valid?,
             "two owners satisfies two partial indexes, so the same node is reachable " <>
               "as two different nodes"
    end
  end
end
