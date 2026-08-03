defmodule CodeMySpecSpex.Story561.Criterion5814Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5814 — Children of one orchestrated tree (sharing
  parent_entity_id) that are simultaneously actionable surface as a
  single wave together.

  Surface: get_next_requirement MCP tool. Three children of one
  Reservations context have their spec files removed; the response
  advertises start_task signatures for each child's spec_file —
  proving they fan out as one parent_entity_id-bounded wave.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Children sharing parent_entity_id fan out as one wave" do
    scenario "all three children's spec_file tasks appear together when their files are missing" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "every child's spec file is removed and re-synced", context do
        env = context.environment

        for child <- [context.child_schema, context.child_repository, context.child_service] do
          :ok = Environments.delete_file(env, Content.spec_path(child.module_name))
        end

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "all three children appear in the response together", context do
        text = context.response_text

        for child <- [context.child_schema, context.child_repository, context.child_service] do
          assert text =~ "entity_id=`#{child.id}`",
                 "expected child #{child.module_name} (id #{child.id}) in the wave. Response: #{text}"
        end

        {:ok, context}
      end

      and_ "the wave stays inside one parent_entity_id — the parent's review_file is not in the wave",
           context do
        text = context.response_text

        refute text =~
                 "requirement_name=`review_file`, entity_type=`component`, entity_id=`#{context.parent_context.id}`",
               "parent's review_file should be gated behind children, response: #{text}"

        {:ok, context}
      end
    end
  end
end
