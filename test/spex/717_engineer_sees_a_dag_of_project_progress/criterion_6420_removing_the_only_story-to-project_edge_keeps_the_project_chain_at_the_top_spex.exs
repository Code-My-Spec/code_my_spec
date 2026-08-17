defmodule CodeMySpecSpex.Story717.Criterion6420Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6420 — Removing the only story-to-project edge keeps the project chain at the top.

  When no project node receives a cross-entity edge from a story or
  component (the schema state after the 2026-05-16 `qa_preflight`
  deletion), the project chain still renders in the TOP band of the
  5-band layout rather than collapsing into a lower band. The
  invariant: the highest node in the graph is a project node.

  Note on the 5-band layout (pre-project → pre-story → components →
  post-story → post-project): project-typed nodes can sit in BOTH the
  pre-project band (the top) AND the post-project band (below stories,
  populated in production by qa_complete et al). What "project chain at
  the top" means is that the TOPMOST node of the graph is a project
  node — not that every project node is above every non-project node.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  Default project setup matches the schema state being tested.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Schema changes that add or remove cross-entity edges between bands do not collapse the layout" do
    scenario "Removing the only story-to-project edge keeps the project chain at the top" do
      given_ "no project gate consumes story output in the current schema (qa_preflight was removed in commit a774e35b)",
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

      then_ "the topmost node in the graph is a project node",
            context do
        nodes = context.graph["nodes"]

        project_ys =
          nodes
          |> Enum.filter(&(&1["attributes"]["entity_type"] == "project"))
          |> Enum.map(& &1["attributes"]["y"])

        all_ys = Enum.map(nodes, & &1["attributes"]["y"])

        assert project_ys != [],
               "expected at least one project node in the graph, got none"

        assert Enum.max(project_ys) == Enum.max(all_ys),
               "expected topmost node to be a project node " <>
                 "(project_top=#{Enum.max(project_ys)}, graph_top=#{Enum.max(all_ys)})"

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
