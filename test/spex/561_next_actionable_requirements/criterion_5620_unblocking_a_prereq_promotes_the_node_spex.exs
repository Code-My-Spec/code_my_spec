defmodule CodeMySpecSpex.Story561.Criterion5620Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5620 — Once the prereq turns green, the previously-
  blocked node appears in the actionable list.

  Surface: get_next_requirement, called twice. First with a missing
  parent spec (so children can't progress), then with the spec
  written and synced (children unblock). The second call must
  advertise child requirements that the first call did not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  @actionable_color "#f5f5f7"
  @satisfied_color "#ff3838"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unblocking a prereq flips its dependent from actionable to satisfied" do
    scenario "parent spec_file renders actionable when missing, satisfied after re-write" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the parent context's spec file is removed and re-synced", context do
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

      when_ "the engineer opens the requirements graph in the blocked state", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :blocked_graph, GraphAssertions.extract_graph!(html))}
      end

      and_ "the parent spec is rewritten and re-synced", context do
        :ok =
          Environments.write_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name),
            Content.context_spec(context.parent_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      and_ "the engineer re-opens the requirements graph in the unblocked state", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :unblocked_graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the parent spec_file flips from actionable color to satisfied color",
            context do
        parent_id = context.parent_context.id

        blocked_node =
          Enum.find(context.blocked_graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id and
              n["attributes"]["name"] == "spec_file"
          end)

        unblocked_node =
          Enum.find(context.unblocked_graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id and
              n["attributes"]["name"] == "spec_file"
          end)

        assert blocked_node && blocked_node["attributes"]["color"] == @actionable_color,
               "expected parent spec_file to render as actionable (#{@actionable_color}) in the blocked state, got #{inspect(blocked_node && blocked_node["attributes"]["color"])}"

        assert unblocked_node && unblocked_node["attributes"]["color"] == @satisfied_color,
               "expected parent spec_file to render as satisfied (#{@satisfied_color}) in the unblocked state, got #{inspect(unblocked_node && unblocked_node["attributes"]["color"])}"

        {:ok, context}
      end
    end
  end
end
