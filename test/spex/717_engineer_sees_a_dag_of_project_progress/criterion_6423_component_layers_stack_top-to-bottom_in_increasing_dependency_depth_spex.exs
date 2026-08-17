defmodule CodeMySpecSpex.Story717.Criterion6423Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6423 — Component layers stack top-to-bottom in increasing dependency depth.

  When the project has components at different dependency depths,
  depth-0 components (no outgoing component dependencies) render at
  a higher y than deeper-depth components in the component zone.

  Setup uses `:cross_context_dependency` which seeds Users (depth 0,
  no outgoing deps) and Stories (depth 1, depends on Users). Stories
  context should render below Users context in the graph.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The component zone lays out components by dependency depth — layers stack top-to-bottom in increasing depth" do
    scenario "Component layers stack top-to-bottom in increasing dependency depth" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "the depth-0 component (Users) renders at a higher y than the depth-1 component (Stories)",
            context do
        users_ys = component_ys(context.graph, context.users_context.id)
        stories_ys = component_ys(context.graph, context.stories_context.id)

        assert users_ys != [], "expected Users component nodes in the graph"
        assert stories_ys != [], "expected Stories component nodes in the graph"

        # Compare the top y of each component (max y, since y grows upward in
        # sigma's coordinate system as used by the projector).
        users_top = Enum.max(users_ys)
        stories_top = Enum.max(stories_ys)

        assert users_top > stories_top,
               "expected Users (depth 0, top y=#{users_top}) above Stories (depth 1, top y=#{stories_top})"

        {:ok, context}
      end
    end
  end

  defp component_ys(graph, component_id) do
    graph["nodes"]
    |> Enum.filter(fn n ->
      n["attributes"]["entity_type"] == "component" and
        n["attributes"]["entity_id"] == component_id
    end)
    |> Enum.map(& &1["attributes"]["y"])
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
