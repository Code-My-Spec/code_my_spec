defmodule CodeMySpecSpex.Story717.Criterion6416Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6416 — Project chain edges flow downward toward later gates.

  When the engineer opens the requirements graph view and the project
  chain has at least two project nodes with a dependency edge between
  them, the source endpoint sits above the target endpoint — the project
  chain lays out as a single vertical column at the top of the canvas.

  Surface: `/projects/:project_name/requirements/graph?preload=true`
  LiveView render. We extract the `data-graph` JSON from the rendered
  `#sigma-graph` element and assert on its `nodes` / `edges` shape.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Intra-entity dependency edges flow toward their target — downward in the vertical project chain column" do
    scenario "Project chain edges flow downward toward later gates" do
      given_ "the project chain has at least two project nodes (the default project always exposes a chain of gates)",
             context do
        {:ok, context}
      end

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "every intra-project edge flows downward — source.y > target.y",
            context do
        nodes_by_key = Map.new(context.graph["nodes"], fn n -> {n["key"], n} end)

        project_edges =
          for e <- context.graph["edges"],
              source = Map.get(nodes_by_key, e["source"]),
              target = Map.get(nodes_by_key, e["target"]),
              source != nil and target != nil,
              source["attributes"]["entity_type"] == "project",
              target["attributes"]["entity_type"] == "project",
              do: {source, target, e}

        assert project_edges != [],
               "expected at least one project→project edge, got none. graph nodes/edges:\n#{inspect(context.graph)}"

        violations =
          for {source, target, e} <- project_edges,
              sx = source["attributes"]["x"],
              sy = source["attributes"]["y"],
              tx = target["attributes"]["x"],
              ty = target["attributes"]["y"],
              not (sy > ty),
              do: {e["key"], sx, sy, tx, ty}

        assert violations == [],
               "edges that do not flow downward in the project column: #{inspect(violations)}"

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
