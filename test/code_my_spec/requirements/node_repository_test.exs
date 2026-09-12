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

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.{Edge, Node, NodeRepository, Projection, Requirement, RequirementGraph}

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

  describe "a component that was visited and produced nothing" do
    # The distinction this exists for: "nobody loaded this component" and "this
    # component was loaded and yielded no requirements" both leave it out of the
    # produced node set, and only the first should keep its rows.
    #
    # The second is ordinary. `graph_for_type/1` filters a template by the
    # project's configuration, and `schema_graph/0` is `spec_file` and
    # `spec_valid` — so on a project with `require_specs: false` every schema
    # component computes zero nodes. Measured on Code My Spec: 84 schema
    # components each holding an `implementation_file` row their current type no
    # longer defines, which `Projection.rehydrate/2` then dropped on every read,
    # so the graph read back 1844 nodes against a published 2009 — permanently,
    # because nothing would ever reap them (cc4745dc).
    test "has its departed rows reaped", %{scope: scope} do
      component = component_fixture(scope)

      NodeRepository.upsert_all(scope, [node("component", component.id, "implementation_file")])

      assert Repo.aggregate(Node, :count) == 1

      # The next pass visits it and produces nothing for it — the empty-template
      # case — so its row is departed.
      NodeRepository.upsert_all(scope, [], %{components: [component.id], stories: []})

      assert Repo.aggregate(Node, :count) == 0,
             """
             A component that was visited and produced no requirements kept its
             rows.

             Every later read finds them and drops them — `rehydrate/2` has no
             definition for a name the component's type no longer defines — so
             the projection reads back short of what the publish counted, for
             good. That is the 1844-against-2009 this was diagnosed from.
             """
    end

    test "a component nobody visited keeps its rows", %{scope: scope} do
      component = component_fixture(scope)

      NodeRepository.upsert_all(scope, [node("component", component.id, "implementation_file")])

      # Not in the visited set at all — filtered out, or belonging to work this
      # pass did not load. Its rows are not this computation's to remove.
      NodeRepository.upsert_all(scope, [], %{components: [], stories: []})

      assert Repo.aggregate(Node, :count) == 1,
             "a component outside this computation must not be treated as departed"
    end
  end

  describe "a caller with no checkout to name" do
    # `Projection.vantage/1` resolves `active_working_copy_id: nil` — the UI
    # path — to the project's *default* working copy whenever one is set, so a
    # person's browser reads that checkout's honest state rather than a blend
    # of every checkout's files. `upsert_all/3` used to persist under the raw
    # field instead, which is always literal `nil` for that same caller.
    #
    # The two never agreed once a project had a default working copy: every UI
    # publish landed under `nil` and no UI read would ever look there again.
    # Measured on Code My Spec, cc4745dc: `verify_round_trip/4` logged "the
    # projection does not round-trip" on every single publish, and
    # `RequirementGraph.served_graph/3`'s short-read guard refused every cache
    # hit as a result — the page recomputed on every visit, forever. Not the
    # `definition_for/2`/config-filtering mismatch this was first suspected to
    # be: a direct read of the rows this test writes shows zero dropped by
    # `Projection.rehydrate/2` either way. The row the publish wrote was
    # simply never where the read went looking.
    test "a nil-scope publish lands where a nil-scope read will look for it", %{scope: scope} do
      {:ok, _project} =
        Projects.update_project(scope, scope.active_project, %{
          default_working_copy_id: scope.active_working_copy_id
        })

      component = component_fixture(scope)
      ui_scope = %{scope | active_working_copy_id: nil}

      NodeRepository.upsert_all(ui_scope, [
        node("component", component.id, "implementation_file")
      ])

      row = Repo.one!(Node)

      assert row.working_copy_id == scope.active_working_copy_id, """
      A publish with no checkout named must land where `Projection.vantage/1`
      will look for it on the next read with no checkout named — the
      project's default working copy, once it has one — not under the raw
      `nil`, which no read of this project will ever resolve back to.
      """

      ctx = %{
        components: [component],
        components_by_id: %{component.id => component},
        stories: []
      }

      {nodes, _edges} = Projection.load(ui_scope, ctx)

      assert length(nodes) == 1, """
      This is the actual symptom behind cc4745dc: a graph published from the
      UI read back short on the very next UI read, because the write and the
      read resolved the same nil-scope caller to two different working
      copies.
      """
    end
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

    # The half `upsert_all/2` was missing. Inserting and updating without ever
    # removing meant every node ever computed stayed a row, so a graph that
    # stopped containing a requirement kept serving it as work.
    #
    # Live consequence: the projection held 2,783 nodes where the computation
    # produced 1,357 — 798 `spec_file` and 791 `test_file` rows for a project
    # whose configuration no longer requires them. The projection agreed with
    # itself perfectly, which is why the round-trip tests never caught it.
    test "a node no longer in the graph stops being a row", %{scope: scope} do
      project_id = scope.active_project_id

      NodeRepository.upsert_all(scope, [
        node("project", project_id, "stories_exist"),
        node("project", project_id, "a_requirement_since_dropped")
      ])

      assert Repo.aggregate(Node, :count) == 2

      NodeRepository.upsert_all(scope, [node("project", project_id, "stories_exist")])

      assert Repo.aggregate(Node, :count) == 1,
             "a requirement the graph stopped producing must stop being reported, " <>
               "or an agent is handed work its project does not have"

      assert Repo.one!(Node).name == "stories_exist"
    end

    # Removal is scoped to what this computation covered. A component the graph
    # did not visit keeps its rows rather than being read as departed.
    test "another entity's nodes are left alone", %{scope: scope} do
      project_id = scope.active_project_id
      component = component_fixture(scope, %{type: "context"})

      NodeRepository.upsert_all(scope, [
        node("project", project_id, "stories_exist"),
        node("component", component.id, "implementation_file")
      ])

      assert Repo.aggregate(Node, :count) == 2

      # A computation covering only the project entity.
      NodeRepository.upsert_all(scope, [node("project", project_id, "stories_exist")])

      assert Repo.aggregate(Node, :count) == 2,
             "the component was not part of this computation, so its nodes are not " <>
               "evidence of anything having been dropped"
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
      assert nodes != [], "a project with no nodes makes this test vacuous"

      assert Repo.aggregate(Node, :count) == length(nodes),
             "every computed node should have a row, or the projection is partial " <>
               "in a way nothing would notice until a reader depended on it"

      assert Repo.aggregate(Edge, :count) == length(edges)
    end

    # The round-trip check runs on the write path, so a computation whose rows
    # do not read back the way they were written says so. This asserts it stays
    # silent on a healthy graph — a check that cried wolf on every stop hook
    # would be muted within a day.
    test "a healthy computation logs no round-trip complaint", %{scope: scope} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RequirementGraph.compute_graph(scope)
        end)

      refute log =~ "does not round-trip"
    end

    # The bug the check exists for: rows present that the computation did not
    # produce. Writing one behind the projection's back is the cheapest way to
    # make the rows disagree with what was just written.
    test "rows that outlive the computation are reported", %{scope: scope} do
      RequirementGraph.compute_graph(scope)

      NodeRepository.upsert_all(scope, [
        node("project", scope.active_project_id, "a_requirement_nothing_computes")
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Force a republish: the fingerprint gates the write, and nothing
          # about the project moved.
          Repo.delete_all(CodeMySpec.Requirements.CachedGraph)
          RequirementGraph.compute_graph(scope)
        end)

      refute log =~ "a_requirement_nothing_computes",
             "the stray row should have been deleted by the write, not reported by it"
    end

    # Six `infrastructure` components on the live project carry rows from a
    # configuration that once produced them. The graph produces no nodes for
    # that type now, so they are never in scope for deletion — they just sit
    # there.
    #
    # They are invisible rather than phantom work: `rehydrate/2` drops a row
    # whose name has no definition for its entity type, so the projection never
    # returns them. This asserts that, because the round-trip check compares
    # against everything the projection *does* return — if these surfaced, it
    # would warn on every computation forever and be muted within a day.
    test "rows for a type the graph no longer covers stay out of the projection",
         %{scope: scope} do
      component = component_fixture(scope, %{type: "infrastructure"})

      NodeRepository.upsert_all(scope, [node("component", component.id, "spec_file")])
      assert Repo.aggregate(Node, :count) >= 1

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RequirementGraph.compute_graph(scope)
        end)

      refute log =~ "does not round-trip",
             "an unrehydratable row must not read as a projection defect — it is " <>
               "residue, and warning about it every time teaches everyone to ignore " <>
               "the one warning that matters"
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
