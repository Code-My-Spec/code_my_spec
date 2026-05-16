defmodule CodeMySpecSpex.Story562.Criterion5600Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5600 — tests_passing with no failures recorded but
  missing implementation_file renders as not satisfied.

  Surface: requirements graph LiveView. This is the vacuous-truth
  case: a `tests_passing` check would individually return "no
  failures recorded" if there were no implementation file to fail
  against, but that doesn't make it satisfied — its prerequisite
  (`implementation_file`) is missing, so the parent must render
  unsatisfied.

  This is the rule that drives the satisfaction-rewrite (kills the
  separate `clamp_satisfaction` pass). Whether it passes today
  depends on whether clamping handles this case correctly.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "tests_passing is not vacuously satisfied" do
    scenario "tests_passing renders unsatisfied when implementation_file is missing" do
      given_ :context_with_three_children

      and_ "the schema child's implementation file is removed", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(context.child_schema.module_name)
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

      then_ "the parent's tests_passing is not satisfied vacuously",
            context do
        satisfied_color = "#ff3838"

        satisfied_tests_passing =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_id"] == context.parent_context.id and
              n["attributes"]["name"] == "tests_passing" and
              n["attributes"]["color"] == satisfied_color
          end)

        assert satisfied_tests_passing == [],
               "expected parent's tests_passing to render unsatisfied because a child's implementation_file is missing, found it satisfied"

        {:ok, context}
      end
    end
  end
end
