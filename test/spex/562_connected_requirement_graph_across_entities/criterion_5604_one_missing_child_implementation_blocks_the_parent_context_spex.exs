defmodule CodeMySpecSpex.Story562.Criterion5604Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5604 — One missing child implementation surfaces as a
  locally unsatisfied node; the parent context's terminal does NOT
  lie about its own state.

  Under the local-truth redesign (rule ac254f5d), satisfaction reflects
  only each node's own check. A missing child impl makes the child's
  `implementation_file` locally unsatisfied; whether the parent's
  terminal is satisfied is governed by the parent's own check, not by
  cascading from the child.

  This spec pins the rendered surface state: the deleted child's
  implementation_file node renders in the non-satisfied color, and the
  parent's nodes report whatever their own local checks say (the spec
  does not assert the parent is unsatisfied — that would re-introduce
  the cascade we removed).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Missing child implementation renders as locally unsatisfied without cascading" do
    scenario "deleted child impl shows up as unsatisfied in the rendered graph" do
      given_ :context_with_three_children

      and_ "the schema child's implementation file is removed", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(context.child_schema.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the child's implementation_file node renders as not satisfied",
            context do
        satisfied_color = "#ff3838"

        impl_node =
          Enum.find(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == context.child_schema.id and
              n["attributes"]["name"] == "implementation_file"
          end)

        assert impl_node,
               "expected the deleted child's implementation_file node to be present in the graph"

        refute impl_node["attributes"]["color"] == satisfied_color,
               "expected the deleted child's implementation_file to render as not satisfied, got color #{impl_node["attributes"]["color"]}"

        {:ok, context}
      end
    end
  end
end
