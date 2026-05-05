defmodule CodeMySpecSpex.Story562.Criterion5608Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5608 — A sibling depending on another stays blocked
  while the depended-on and unrelated siblings remain actionable.

  Surface: requirements graph LiveView. With three siblings — two
  unrelated and one declaring a dependency — the dependent must
  have an edge from the depended-on into its own chain. Independent
  siblings must remain free of incoming edges from sibling chains.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dependent sibling is gated by its dependency" do
    scenario "an edge runs from the dependency into the dependent's chain" do
      given_ :two_siblings_one_depends_on_other

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the dependent has an incoming edge from the dependency",
            context do
        dependency_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.dependency.id end)
          |> MapSet.new(& &1["key"])

        dependent_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.dependent.id end)
          |> MapSet.new(& &1["key"])

        gating_edges =
          Enum.filter(context.graph["edges"], fn e ->
            MapSet.member?(dependency_keys, e["source"]) and
              MapSet.member?(dependent_keys, e["target"])
          end)

        assert gating_edges != [],
               "expected at least one edge from #{context.dependency.module_name} into #{context.dependent.module_name}, found none"

        {:ok, context}
      end

      and_ "the independent sibling has no incoming edges from the dependent or dependency",
           context do
        independent_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.independent_a.id end)
          |> MapSet.new(& &1["key"])

        from_dependency_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.dependency.id end)
          |> MapSet.new(& &1["key"])

        from_dependent_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.dependent.id end)
          |> MapSet.new(& &1["key"])

        false_serialization_edges =
          Enum.filter(context.graph["edges"], fn e ->
            MapSet.member?(independent_keys, e["target"]) and
              (MapSet.member?(from_dependency_keys, e["source"]) or
                 MapSet.member?(from_dependent_keys, e["source"]))
          end)

        assert false_serialization_edges == [],
               "expected the independent sibling to have no incoming edges from the dependency or dependent, found: #{inspect(Enum.map(false_serialization_edges, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end
    end
  end
end
