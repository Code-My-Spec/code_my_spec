defmodule CodeMySpecSpex.Story561.Criterion5619Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5619 — A node whose own check would pass but with one
  unsatisfied prereq does not appear in actionable.

  Surface: get_next_requirement. We exercise this by deleting the
  parent context's spec file (so spec_valid is unsatisfied), then
  asserting that downstream child-scoped requirements (which depend
  on parent.spec_valid through the template) are not advertised —
  the chain is correctly gated.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  @actionable_color "#f5f5f7"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Blocked nodes do not render as actionable until their prereqs are satisfied" do
    scenario "child review work does not render actionable while parent spec is missing" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the parent context's spec file is removed", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name)
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

      then_ "no review_file or review_valid node renders in actionable color",
            context do
        blocked_names = ["review_file", "review_valid"]

        actionable_reviews =
          Enum.filter(context.graph["nodes"], fn n ->
            n["attributes"]["name"] in blocked_names and
              n["attributes"]["color"] == @actionable_color
          end)

        assert actionable_reviews == [],
               "expected review_file/review_valid to NOT render actionable while parent spec is missing, found: #{inspect(Enum.map(actionable_reviews, &{&1["attributes"]["entity_id"], &1["attributes"]["name"]}))}"

        {:ok, context}
      end

      and_ "the parent's spec_file renders in actionable color", context do
        parent_id = context.parent_context.id

        node =
          Enum.find(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id and
              n["attributes"]["name"] == "spec_file"
          end)

        assert node,
               "expected parent's spec_file node in the graph"

        assert node["attributes"]["color"] == @actionable_color,
               "expected parent's spec_file to render as actionable (#{@actionable_color}), got #{node["attributes"]["color"]}"

        {:ok, context}
      end
    end
  end
end
