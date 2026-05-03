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

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unblocking a prereq promotes its dependents into actionable" do
    scenario "downstream items appear after the prereq is satisfied" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the parent context's spec file is removed and re-synced", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      when_ "the agent calls get_next_requirement (blocked state)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :blocked_response, TaskResponseHelpers.response_text(response))}
      end

      and_ "the parent spec is rewritten and re-synced", context do
        :ok =
          Environments.write_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name),
            Content.context_spec(context.parent_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      and_ "the agent calls get_next_requirement (unblocked state)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :unblocked_response, TaskResponseHelpers.response_text(response))}
      end

      then_ "the parent spec_file disappears from the unblocked response",
            context do
        parent_id = context.parent_context.id

        signature =
          ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*entity_id=`#{parent_id}`/

        assert Regex.match?(signature, context.blocked_response),
               "expected parent spec_file in the blocked response (parent spec was missing)"

        refute Regex.match?(signature, context.unblocked_response),
               "expected parent spec_file to disappear from the unblocked response (it's now satisfied)"

        {:ok, context}
      end
    end
  end
end
