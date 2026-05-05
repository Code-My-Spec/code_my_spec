defmodule CodeMySpecSpex.Story562.Criterion5606Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5606 — A single failing story blocks project qa_preflight
  even when other stories are green.

  Surface: requirements graph LiveView. With four stories where only
  one's surface is missing its implementation file, the project's
  terminal requirement (`qa_preflight`) cannot be satisfied. The
  graph view must reflect this — no project terminal renders as
  satisfied while any story remains incomplete.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Project qa_preflight is blocked by a single incomplete story" do
    scenario "project terminal is not satisfied while any story is incomplete" do
      given_ :project_with_four_stories

      and_ "one story's surface implementation is removed", context do
        first_surface = List.first(context.surfaces)

        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(first_surface.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no project-level terminal node is satisfied",
            context do
        satisfied_color = "#60a5fa"

        satisfied_project_terminals =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_type"] == "project" and
              n["attributes"]["color"] == satisfied_color and
              n["attributes"]["name"] == "qa_preflight"
          end)

        assert satisfied_project_terminals == [],
               "expected qa_preflight to render unsatisfied while a story is incomplete, but it rendered satisfied"

        {:ok, context}
      end
    end
  end
end
