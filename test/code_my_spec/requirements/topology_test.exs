defmodule CodeMySpec.Requirements.TopologyTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.Topology

  # ── fixtures ──────────────────────────────────────────────────────

  defp req(opts) do
    %Requirement{
      entity_type: Keyword.fetch!(opts, :entity_type),
      entity_id: Keyword.fetch!(opts, :entity_id),
      entity_name: Keyword.get(opts, :entity_name, "name"),
      parent_entity_id: Keyword.get(opts, :parent_entity_id),
      parent_entity_name: Keyword.get(opts, :parent_entity_name),
      name: Keyword.fetch!(opts, :name),
      description: "",
      satisfied: false,
      satisfied_by: nil,
      scope: :local,
      execution_type: :main_agent,
      validation_type: :automatic,
      orchestrated_by: nil,
      prerequisites: [],
      details: nil
    }
  end

  defp edge(from, to), do: %{from: from, to: to}
  defp k(n), do: {n.entity_type, n.entity_id, n.name}

  # Two-context project, each with a story, plus one project node.
  # Edges form a typical chain: story → component → component → story → project.
  defp sample_graph do
    proj_setup = req(entity_type: "project", entity_id: 1, name: "project_setup")
    proj_qa = req(entity_type: "project", entity_id: 1, name: "qa_preflight")

    story_a_in = req(entity_type: "story", entity_id: 10, name: "bdd_specs_exist")
    story_a_out = req(entity_type: "story", entity_id: 10, name: "bdd_specs_passing")

    comp_a_spec = req(entity_type: "component", entity_id: 100, name: "spec_file")
    comp_a_impl = req(entity_type: "component", entity_id: 100, name: "implementation_file")

    nodes = [proj_setup, proj_qa, story_a_in, story_a_out, comp_a_spec, comp_a_impl]

    edges = [
      edge(k(proj_setup), k(proj_qa)),
      edge(k(story_a_in), k(comp_a_spec)),
      edge(k(comp_a_spec), k(comp_a_impl)),
      edge(k(comp_a_impl), k(story_a_out)),
      edge(k(story_a_out), k(proj_qa))
    ]

    %{
      nodes: nodes,
      edges: edges,
      proj_setup: proj_setup,
      proj_qa: proj_qa,
      story_a_in: story_a_in,
      story_a_out: story_a_out,
      comp_a_spec: comp_a_spec,
      comp_a_impl: comp_a_impl
    }
  end

  # ── partition_by_entity_type/2 ────────────────────────────────────

  describe "partition_by_entity_type/2" do
    test "buckets nodes into project / story / component" do
      g = sample_graph()
      result = Topology.partition_by_entity_type(g.nodes, g.edges)

      assert Map.keys(result) |> Enum.sort() == ~w(component project story)

      {project_nodes, _} = Map.fetch!(result, "project")
      {story_nodes, _} = Map.fetch!(result, "story")
      {comp_nodes, _} = Map.fetch!(result, "component")

      assert MapSet.new(project_nodes, & &1.name) == MapSet.new(["project_setup", "qa_preflight"])
      assert MapSet.new(story_nodes, & &1.name) == MapSet.new(["bdd_specs_exist", "bdd_specs_passing"])
      assert MapSet.new(comp_nodes, & &1.name) == MapSet.new(["spec_file", "implementation_file"])
    end

    test "intra-type edges only — cross-type edges drop out" do
      g = sample_graph()
      result = Topology.partition_by_entity_type(g.nodes, g.edges)

      {_, project_edges} = Map.fetch!(result, "project")
      {_, story_edges} = Map.fetch!(result, "story")
      {_, comp_edges} = Map.fetch!(result, "component")

      assert project_edges == [edge(k(g.proj_setup), k(g.proj_qa))]
      assert story_edges == []
      assert comp_edges == [edge(k(g.comp_a_spec), k(g.comp_a_impl))]
    end

    test "empty graph yields empty map" do
      assert Topology.partition_by_entity_type([], []) == %{}
    end
  end

  # ── partition_by_entity/2 ──────────────────────────────────────────

  describe "partition_by_entity/2" do
    test "buckets nodes per (entity_type, entity_id)" do
      g = sample_graph()
      result = Topology.partition_by_entity(g.nodes, g.edges)

      assert MapSet.new(Map.keys(result)) ==
               MapSet.new([{"project", 1}, {"story", 10}, {"component", 100}])
    end

    test "edges are intra-entity only" do
      g = sample_graph()
      result = Topology.partition_by_entity(g.nodes, g.edges)

      {_, comp_edges} = Map.fetch!(result, {"component", 100})
      assert comp_edges == [edge(k(g.comp_a_spec), k(g.comp_a_impl))]

      {_, story_edges} = Map.fetch!(result, {"story", 10})
      # Story's two nodes have no direct edge between them in this graph.
      assert story_edges == []
    end
  end

  # ── partition_by_parent_entity/2 ──────────────────────────────────

  describe "partition_by_parent_entity/2" do
    test "groups by parent_entity_id, with nil bucket for unorchestrated" do
      orchestrated_a = req(entity_type: "component", entity_id: 200, parent_entity_id: 50, name: "spec_file")
      orchestrated_b = req(entity_type: "component", entity_id: 201, parent_entity_id: 50, name: "spec_file")
      unorchestrated = req(entity_type: "component", entity_id: 300, parent_entity_id: nil, name: "spec_file")

      nodes = [orchestrated_a, orchestrated_b, unorchestrated]
      edges = [edge(k(orchestrated_a), k(orchestrated_b))]

      result = Topology.partition_by_parent_entity(nodes, edges)

      assert MapSet.new(Map.keys(result)) == MapSet.new([50, nil])

      {bucket_50, edges_50} = Map.fetch!(result, 50)
      assert MapSet.new(bucket_50, & &1.entity_id) == MapSet.new([200, 201])
      assert edges_50 == [edge(k(orchestrated_a), k(orchestrated_b))]

      {bucket_nil, _} = Map.fetch!(result, nil)
      assert Enum.map(bucket_nil, & &1.entity_id) == [300]
    end
  end

  # ── cross_entity_edges/1 ──────────────────────────────────────────

  describe "cross_entity_edges/1" do
    test "returns only edges where source and target have different entity_type" do
      g = sample_graph()
      cross = Topology.cross_entity_edges(g.edges)

      expected =
        MapSet.new([
          edge(k(g.story_a_in), k(g.comp_a_spec)),
          edge(k(g.comp_a_impl), k(g.story_a_out)),
          edge(k(g.story_a_out), k(g.proj_qa))
        ])

      assert MapSet.new(cross) == expected
    end

    test "intra-type-only graph returns empty list" do
      a = req(entity_type: "project", entity_id: 1, name: "x")
      b = req(entity_type: "project", entity_id: 1, name: "y")
      assert Topology.cross_entity_edges([edge(k(a), k(b))]) == []
    end
  end

  # ── cross_entity_sources / sinks ──────────────────────────────────

  describe "cross_entity_sources/2 and cross_entity_sinks/2" do
    test "sources are nodes with outgoing cross-entity edges" do
      g = sample_graph()
      sources = Topology.cross_entity_sources(g.nodes, g.edges)

      assert MapSet.new(sources, & &1.name) ==
               MapSet.new(["bdd_specs_exist", "implementation_file", "bdd_specs_passing"])
    end

    test "sinks are nodes with incoming cross-entity edges" do
      g = sample_graph()
      sinks = Topology.cross_entity_sinks(g.nodes, g.edges)

      assert MapSet.new(sinks, & &1.name) ==
               MapSet.new(["spec_file", "bdd_specs_passing", "qa_preflight"])
    end

    test "qa_preflight is a sink but not a source — it's the project's fan-in seam" do
      g = sample_graph()
      sources = Topology.cross_entity_sources(g.nodes, g.edges)
      sinks = Topology.cross_entity_sinks(g.nodes, g.edges)

      refute Enum.any?(sources, &(&1.name == "qa_preflight"))
      assert Enum.any?(sinks, &(&1.name == "qa_preflight"))
    end
  end

  # ── depth_map/2 ───────────────────────────────────────────────────

  describe "depth_map/2" do
    test "sources have depth 0; chain monotonically increases" do
      g = sample_graph()
      depths = Topology.depth_map(g.nodes, g.edges)

      assert depths[k(g.proj_setup)] == 0
      assert depths[k(g.story_a_in)] == 0
      assert depths[k(g.comp_a_spec)] == 1
      assert depths[k(g.comp_a_impl)] == 2
      assert depths[k(g.story_a_out)] == 3
      assert depths[k(g.proj_qa)] == 4
    end

    test "isolated node has depth 0" do
      n = req(entity_type: "project", entity_id: 1, name: "alone")
      depths = Topology.depth_map([n], [])
      assert depths[k(n)] == 0
    end

    test "diamond — two sources joining downstream" do
      a = req(entity_type: "project", entity_id: 1, name: "a")
      b = req(entity_type: "project", entity_id: 1, name: "b")
      c = req(entity_type: "project", entity_id: 1, name: "c")
      d = req(entity_type: "project", entity_id: 1, name: "d")

      edges = [edge(k(a), k(c)), edge(k(b), k(c)), edge(k(c), k(d))]
      depths = Topology.depth_map([a, b, c, d], edges)

      assert depths[k(a)] == 0
      assert depths[k(b)] == 0
      assert depths[k(c)] == 1
      assert depths[k(d)] == 2
    end
  end

  # ── indegree / outdegree ──────────────────────────────────────────

  describe "indegree/2 and outdegree/2" do
    test "counts incoming and outgoing edges per node" do
      g = sample_graph()

      indeg = Topology.indegree(g.nodes, g.edges)
      outdeg = Topology.outdegree(g.nodes, g.edges)

      assert indeg[k(g.proj_setup)] == 0
      assert outdeg[k(g.proj_setup)] == 1

      assert indeg[k(g.proj_qa)] == 2
      assert outdeg[k(g.proj_qa)] == 0
    end

    test "fan-in is detectable via indegree without naming the node" do
      g = sample_graph()
      indeg = Topology.indegree(g.nodes, g.edges)

      fan_in =
        g.nodes
        |> Enum.filter(fn n -> Map.fetch!(indeg, k(n)) >= 2 end)
        |> Enum.map(& &1.name)

      assert fan_in == ["qa_preflight"]
    end
  end

  # ── descendants_of/2 ──────────────────────────────────────────────

  describe "descendants_of/2" do
    test "returns every key reachable forward from the starting set" do
      g = sample_graph()
      descendants = Topology.descendants_of([g.story_a_in], g.edges)

      assert MapSet.new([k(g.comp_a_spec), k(g.comp_a_impl), k(g.story_a_out), k(g.proj_qa)]) ==
               descendants
    end

    test "excludes the starting set itself" do
      g = sample_graph()
      descendants = Topology.descendants_of([g.proj_setup], g.edges)
      refute MapSet.member?(descendants, k(g.proj_setup))
    end

    test "starting from a sink yields empty set" do
      g = sample_graph()
      descendants = Topology.descendants_of([g.proj_qa], g.edges)
      assert MapSet.size(descendants) == 0
    end

    test "multiple starting nodes union their reachability" do
      g = sample_graph()
      descendants = Topology.descendants_of([g.comp_a_spec, g.proj_setup], g.edges)

      assert MapSet.member?(descendants, k(g.comp_a_impl))
      assert MapSet.member?(descendants, k(g.story_a_out))
      assert MapSet.member?(descendants, k(g.proj_qa))
    end
  end

  # ── fans_out_to_children?/3 ───────────────────────────────────────

  # ── transitive_reduction/1 ────────────────────────────────────────

  describe "transitive_reduction/1" do
    test "drops a direct edge when a longer path exists" do
      a = req(entity_type: "p", entity_id: 1, name: "a")
      b = req(entity_type: "p", entity_id: 1, name: "b")
      c = req(entity_type: "p", entity_id: 1, name: "c")

      edges = [edge(k(a), k(b)), edge(k(b), k(c)), edge(k(a), k(c))]
      reduced = Topology.transitive_reduction(edges)

      assert MapSet.new(reduced) ==
               MapSet.new([edge(k(a), k(b)), edge(k(b), k(c))])
    end

    test "preserves edges with no alternative path (linear chain)" do
      a = req(entity_type: "p", entity_id: 1, name: "a")
      b = req(entity_type: "p", entity_id: 1, name: "b")
      c = req(entity_type: "p", entity_id: 1, name: "c")

      edges = [edge(k(a), k(b)), edge(k(b), k(c))]
      assert Topology.transitive_reduction(edges) == edges
    end

    test "preserves a diamond's branch edges (two distinct paths to the same target)" do
      # a → b, a → c, b → d, c → d  — both b→d and c→d survive,
      # neither has a longer path through the other.
      a = req(entity_type: "p", entity_id: 1, name: "a")
      b = req(entity_type: "p", entity_id: 1, name: "b")
      c = req(entity_type: "p", entity_id: 1, name: "c")
      d = req(entity_type: "p", entity_id: 1, name: "d")

      edges = [edge(k(a), k(b)), edge(k(a), k(c)), edge(k(b), k(d)), edge(k(c), k(d))]
      reduced = Topology.transitive_reduction(edges)

      assert MapSet.new(reduced) == MapSet.new(edges)
    end

    test "drops a→d when a→b→c→d exists alongside the direct edge" do
      a = req(entity_type: "p", entity_id: 1, name: "a")
      b = req(entity_type: "p", entity_id: 1, name: "b")
      c = req(entity_type: "p", entity_id: 1, name: "c")
      d = req(entity_type: "p", entity_id: 1, name: "d")

      edges = [
        edge(k(a), k(b)),
        edge(k(b), k(c)),
        edge(k(c), k(d)),
        edge(k(a), k(d))
      ]

      reduced = Topology.transitive_reduction(edges)

      assert MapSet.new(reduced) ==
               MapSet.new([edge(k(a), k(b)), edge(k(b), k(c)), edge(k(c), k(d))])
    end

    test "empty edge list reduces to empty" do
      assert Topology.transitive_reduction([]) == []
    end
  end

  describe "fans_out_to_children?/3" do
    test "true when a parent-scope node has outgoing edges to nodes of the same type with different entity_id" do
      parent = req(entity_type: "component", entity_id: 1, name: "spec_valid", parent_entity_id: 1)
      child_a = req(entity_type: "component", entity_id: 2, name: "spec_file", parent_entity_id: 1)
      child_b = req(entity_type: "component", entity_id: 3, name: "spec_file", parent_entity_id: 1)

      edges = [edge(k(parent), k(child_a)), edge(k(parent), k(child_b))]

      assert Topology.fans_out_to_children?(parent, [parent, child_a, child_b], edges)
    end

    test "false when outgoing edges stay within the same entity_id" do
      a = req(entity_type: "component", entity_id: 1, name: "spec_file", parent_entity_id: 1)
      b = req(entity_type: "component", entity_id: 1, name: "spec_valid", parent_entity_id: 1)

      edges = [edge(k(a), k(b))]

      refute Topology.fans_out_to_children?(a, [a, b], edges)
    end

    test "false when outgoing edges cross entity_type" do
      story_node = req(entity_type: "story", entity_id: 10, name: "bdd_specs_exist")
      comp_node = req(entity_type: "component", entity_id: 1, name: "spec_file", parent_entity_id: 1)

      edges = [edge(k(story_node), k(comp_node))]

      refute Topology.fans_out_to_children?(story_node, [story_node, comp_node], edges)
    end

    test "false when node has no outgoing edges" do
      n = req(entity_type: "component", entity_id: 1, name: "tests_passing")
      refute Topology.fans_out_to_children?(n, [n], [])
    end
  end
end
