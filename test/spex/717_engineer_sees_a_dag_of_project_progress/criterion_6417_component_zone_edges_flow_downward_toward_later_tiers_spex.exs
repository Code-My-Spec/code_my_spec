defmodule CodeMySpecSpex.Story717.Criterion6417Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6417 — Component zone edges flow downward toward later tiers.

  When two top-level components have a dependency between them, the
  dependent (source) component sits above the depended-on (target)
  component in the component zone — intra-component edges flow
  strictly downward (source.y > target.y).

  Surface: `/projects/:project_name/requirements/graph?preload=true`
  LiveView render. Filters extracted graph to component→component
  edges and asserts the y-flow invariant.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Intra-entity dependency edges flow toward their target — downward in vertical bands like the component zone" do
    scenario "Component zone edges flow downward toward later tiers" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "every intra-component edge flows downward — source.y > target.y", context do
        nodes_by_key = Map.new(context.graph["nodes"], fn n -> {n["key"], n} end)

        comp_edges =
          for e <- context.graph["edges"],
              source = Map.get(nodes_by_key, e["source"]),
              target = Map.get(nodes_by_key, e["target"]),
              source != nil and target != nil,
              source["attributes"]["entity_type"] == "component",
              target["attributes"]["entity_type"] == "component",
              source["attributes"]["entity_id"] != target["attributes"]["entity_id"],
              do: {source, target, e}

        assert comp_edges != [],
               "expected at least one component→component edge in the cross_context_dependency setup, got none"

        violations =
          for {source, target, e} <- comp_edges,
              sy = source["attributes"]["y"],
              ty = target["attributes"]["y"],
              sy <= ty,
              do: {e["key"], sy, ty}

        assert violations == [],
               "edges that do not flow downward in the component zone: #{inspect(violations)}"

        {:ok, context}
      end
    end
  end

  defp extract_graph(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#sigma-graph")
    |> Floki.attribute("data-graph")
    |> List.first()
    |> Jason.decode!()
  end
end
