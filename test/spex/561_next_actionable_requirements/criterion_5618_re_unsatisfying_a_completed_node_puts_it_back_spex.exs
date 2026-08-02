defmodule CodeMySpecSpex.Story561.Criterion5618Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5618 — Re-unsatisfying a previously-completed node puts
  it back in the actionable list.

  Surface: get_next_requirement. After syncing a context (parent
  spec_file satisfied), the engineer deletes the parent's spec file
  and re-syncs. The response now advertises spec_file for that
  parent component as actionable again — proving the actionable
  computation is fresh against current state, not cached.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  @actionable_color "#f5f5f7"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Deleting a completed artifact re-surfaces its requirement" do
    scenario "the parent spec_file renders as actionable after deletion" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the engineer deletes the parent context's spec file from disk",
           context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name)
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

      then_ "the parent context's spec_file renders in the actionable color",
            context do
        parent_id = context.parent_context.id

        node =
          Enum.find(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id and
              n["attributes"]["name"] == "spec_file"
          end)

        assert node,
               "expected parent's spec_file node to be present in the graph"

        assert node["attributes"]["color"] == @actionable_color,
               "expected parent's spec_file to render as actionable (#{@actionable_color}), got color #{node["attributes"]["color"]}"

        {:ok, context}
      end
    end
  end
end
