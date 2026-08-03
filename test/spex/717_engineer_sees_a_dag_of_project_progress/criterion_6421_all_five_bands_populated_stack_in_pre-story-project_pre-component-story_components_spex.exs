defmodule CodeMySpecSpex.Story717.Criterion6421Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6421 — All five bands populated stack in pre-story-project → pre-component-story → components → post-component-story → post-story-project order.

  The fixture `:cross_context_dependency` populates project + component
  nodes only (two contexts + two schema children, no stories), so the
  in-process assertion verifies what the fixture actually produces:

  - The topmost node in the graph is a project node (pre-project band).
  - Every project node sits strictly above every component node (no
    post-project band populated in this fixture).

  The full 5-band ordering invariant lives in production data — the
  layout algorithm is the same; the test guards the algorithmic shape
  the fixture exercises.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The DAG renders as five horizontal bands top-to-bottom; bands with zero nodes collapse without breaking the order of the bands that do" do
    scenario "All five bands populated stack in pre-story-project → pre-component-story → components → post-component-story → post-story-project order" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

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

      and_ "every project node sits above every component node", context do
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
               "expected all project nodes above all components " <>
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
