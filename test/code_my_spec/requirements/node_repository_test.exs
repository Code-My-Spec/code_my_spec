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

  alias CodeMySpec.Requirements.{Edge, Node, NodeRepository, Requirement, RequirementGraph}

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

  # Edges reference node ids, so they can only be written after the nodes are.
  # These cover the two ways that goes wrong: an edge naming a node this graph
  # does not contain, and a dependency that was removed still being a row.
  describe "replace_edges/3" do
    defp two_nodes(scope) do
      project_id = scope.active_project_id

      keys =
        NodeRepository.upsert_all(scope, [
          node("project", project_id, "stories_exist"),
          node("project", project_id, "architecture_designed")
        ])

      {keys, {"project", project_id, "stories_exist"},
       {"project", project_id, "architecture_designed"}}
    end

    test "an edge becomes a row pointing at both nodes", %{scope: scope} do
      {keys, from, to} = two_nodes(scope)

      assert {:ok, 1} = NodeRepository.replace_edges(scope, [%{from: from, to: to}], keys)

      assert [edge] = Repo.all(Edge)
      assert edge.from_requirement_id == keys[from]
      assert edge.to_requirement_id == keys[to]
    end

    test "recomputing the same graph does not churn the table", %{scope: scope} do
      {keys, from, to} = two_nodes(scope)
      edges = [%{from: from, to: to}]

      {:ok, _} = NodeRepository.replace_edges(scope, edges, keys)
      [first] = Repo.all(Edge)

      NodeRepository.replace_edges(scope, edges, keys)

      assert [second] = Repo.all(Edge)
      assert second.id == first.id, "an unchanged graph should not rewrite its edges"
    end

    # The reason this is `replace` rather than `insert`: a dependency dropped
    # from a definition has to stop being a row, or the graph keeps enforcing an
    # ordering nobody asked for.
    test "an edge that is no longer in the graph is removed", %{scope: scope} do
      {keys, from, to} = two_nodes(scope)

      {:ok, 1} = NodeRepository.replace_edges(scope, [%{from: from, to: to}], keys)
      {:ok, 0} = NodeRepository.replace_edges(scope, [], keys)

      assert Repo.all(Edge) == []
    end

    # `compute_edges/3` already filters to known nodes, so an unknown endpoint
    # here means the two passes disagree. Dropping it beats a foreign key error.
    test "an edge naming a node outside the graph is dropped", %{scope: scope} do
      {keys, from, _to} = two_nodes(scope)
      stranger = {"project", scope.active_project_id, "not_a_node_here"}

      assert {:ok, 0} = NodeRepository.replace_edges(scope, [%{from: from, to: stranger}], keys)
      assert Repo.all(Edge) == []
    end

    test "a self-edge is refused by the changeset", %{scope: scope} do
      {keys, from, _to} = two_nodes(scope)
      id = keys[from]

      changeset =
        Edge.changeset(%Edge{}, %{from_requirement_id: id, to_requirement_id: id})

      refute changeset.valid?,
             "a self-edge is a one-node cycle — the node would never become actionable"
    end

    # The point of the foreign keys. A node going away must not leave an edge
    # pointing at nothing.
    test "deleting a node deletes its edges", %{scope: scope} do
      {keys, from, to} = two_nodes(scope)
      {:ok, 1} = NodeRepository.replace_edges(scope, [%{from: from, to: to}], keys)

      Repo.delete!(Repo.get!(Node, keys[to]))

      assert Repo.all(Edge) == []
    end
  end

  # The wiring. `compute_and_publish/3` writes rows behind the same fingerprint
  # check that gates the blob, so a real computation should leave the two
  # agreeing about how many nodes and edges the graph has.
  #
  # Worth asserting against a computed graph rather than hand-built nodes: the
  # hand-built ones in this file all belong to one project, and the mapping from
  # `node_key/1` to a row id is exactly where three entity types could go wrong.
  describe "a computed graph lands as rows" do
    test "nodes and edges match what compute_graph returned", %{scope: scope} do
      {nodes, edges} = RequirementGraph.compute_graph(scope)

      # Guard against the assertion below passing on 0 == 0.
      assert length(nodes) > 0, "a project with no nodes makes this test vacuous"

      assert Repo.aggregate(Node, :count) == length(nodes),
             "every computed node should have a row, or the projection is partial " <>
               "in a way nothing would notice until a reader depended on it"

      assert Repo.aggregate(Edge, :count) == length(edges)
    end

    test "recomputing an unchanged graph writes nothing new", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      node_count = Repo.aggregate(Node, :count)
      edge_count = Repo.aggregate(Edge, :count)

      RequirementGraph.compute_graph(scope)

      assert Repo.aggregate(Node, :count) == node_count
      assert Repo.aggregate(Edge, :count) == edge_count
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
