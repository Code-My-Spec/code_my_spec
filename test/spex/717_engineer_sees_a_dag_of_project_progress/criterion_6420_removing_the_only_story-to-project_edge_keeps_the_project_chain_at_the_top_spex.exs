defmodule CodeMySpecSpex.Story717.Criterion6420Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6420 — Removing the only story-to-project edge keeps the project chain at the top.

  When no project node receives a cross-entity edge from a story or
  component (the schema state after the 2026-05-16 `qa_preflight`
  deletion), the project chain still renders in the TOP band at y=0
  rather than collapsing into the bottom band — the layout split is
  robust to the absence of cross-entity sinks on project nodes.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  Default project setup matches the schema state being tested (no
  current project gate consumes story output), so no extra fixture
  work is needed.
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
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "every project node renders above the highest non-project node (the top band)",
            context do
        {project_nodes, other_nodes} =
          Enum.split_with(context.graph["nodes"], fn n ->
            n["attributes"]["entity_type"] == "project"
          end)

        assert project_nodes != [],
               "expected at least one project node in the graph, got none"

        project_min_y = project_nodes |> Enum.map(& &1["attributes"]["y"]) |> Enum.min()
        other_max_y = other_nodes |> Enum.map(& &1["attributes"]["y"]) |> Enum.max(fn -> :neg_infinity end)

        # The vertical project chain stacks downward at the top of the
        # canvas; with no cross-entity sink on project nodes the whole
        # chain renders as early_project (above the story zone) rather
        # than collapsing into the bottom band. We assert that the
        # LOWEST project node still sits above the HIGHEST non-project
        # node — i.e. the chain hasn't degenerated into late_project.
        assert other_max_y == :neg_infinity or project_min_y > other_max_y,
               "expected project chain above all non-project nodes; project_min_y=#{project_min_y}, other_max_y=#{other_max_y}"

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
