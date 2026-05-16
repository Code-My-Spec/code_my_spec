defmodule CodeMySpecSpex.Story717.Criterion6422Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6422 — Empty post-story-project band leaves the remaining four bands in correct order.

  When the schema has no project gate consuming story output (the
  current post-`a774e35b` state), the four populated bands —
  pre-story-project, pre-component-story, components,
  post-component-story — still stack in correct order, and no node
  drifts into the empty post-story-project slot at the bottom.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  Default project setup already matches this state.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Bands with zero nodes collapse cleanly without breaking the order of the bands that do" do
    scenario "Empty post-story-project band leaves the remaining four bands in correct order" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "the pre-story project band still sits at the top (y == 0)", context do
        project_nodes =
          Enum.filter(context.graph["nodes"], fn n ->
            n["attributes"]["entity_type"] == "project"
          end)

        assert project_nodes != [], "expected project nodes in the graph"

        ys = Enum.map(project_nodes, & &1["attributes"]["y"])

        assert Enum.max(ys) == 0,
               "expected pre-story project band at top (y == 0), got max y == #{Enum.max(ys)}"

        {:ok, context}
      end

      and_ "no node from any other band drifts into the bottom (below the component zone)",
           context do
        nodes = context.graph["nodes"]

        component_min_y =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "component"))
          |> Enum.map(& &1["attributes"]["y"])
          |> Enum.min(fn -> nil end)

        # Project/story nodes should never sit BELOW any component node in
        # current schema — late_project is empty so the bottom band is the
        # component zone.
        violations =
          for n <- nodes,
              n["attributes"]["entity_type"] in ["project", "story"],
              component_min_y != nil,
              n["attributes"]["y"] < component_min_y,
              do: {n["label"], n["attributes"]["entity_type"], n["attributes"]["y"]}

        assert violations == [],
               "expected no project/story node below component zone (component_min_y=#{component_min_y}); got: #{inspect(violations)}"

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
