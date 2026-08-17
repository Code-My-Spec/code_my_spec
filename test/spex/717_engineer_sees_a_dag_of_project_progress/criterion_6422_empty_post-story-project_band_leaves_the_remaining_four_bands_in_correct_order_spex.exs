defmodule CodeMySpecSpex.Story717.Criterion6422Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6422 — Empty post-story-project band leaves the remaining four bands in correct order.

  When the post-project band (project nodes BELOW the component zone,
  populated in production by qa_complete et al) is empty — as it is in
  the fixture topology this spec exercises — the remaining bands still
  stack in order without any node drifting into the empty slot. The
  fixture (`:cross_context_dependency`) populates project + component
  nodes only; no story-typed nodes appear, and no project node ever
  appears below the component zone. The two invariants the layout must
  hold under this shape:

  1. The topmost node in the graph is a project node (pre-project band
     occupied at the top).
  2. Every project node sits strictly above every component node
     (post-project band is empty — no project drifted past the
     component zone).

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
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
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "the topmost node in the graph is a project node", context do
        nodes = context.graph["nodes"]

        project_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "project"))
          |> Enum.map(& &1["attributes"]["y"])

        all_ys = Enum.map(nodes, & &1["attributes"]["y"])

        assert project_ys != [], "expected project nodes in the graph"

        assert Enum.max(project_ys) == Enum.max(all_ys),
               "expected topmost node to be a project node " <>
                 "(project_top=#{Enum.max(project_ys)}, graph_top=#{Enum.max(all_ys)})"

        {:ok, context}
      end

      and_ "every project node sits above every component node (post-project band empty)",
           context do
        nodes = context.graph["nodes"]

        project_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "project"))
          |> Enum.map(& &1["attributes"]["y"])

        component_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "component"))
          |> Enum.map(& &1["attributes"]["y"])

        assert component_ys != [],
               "expected component nodes from cross_context_dependency fixture"

        assert Enum.min(project_ys) > Enum.max(component_ys),
               "expected all project nodes above all components — " <>
                 "post-project band must be empty in this fixture " <>
                 "(project_min=#{Enum.min(project_ys)}, component_max=#{Enum.max(component_ys)})"

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
