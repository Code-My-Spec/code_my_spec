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

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Deleting a completed artifact re-surfaces its requirement" do
    scenario "the parent spec_file reappears as actionable after deletion" do
      given_ :context_with_three_children

      and_ "the engineer deletes the parent context's spec file from disk",
           context do
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

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the parent context's spec_file is now actionable again",
            context do
        parent_id = context.parent_context.id

        signature =
          ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*entity_id=`#{parent_id}`/

        assert Regex.match?(signature, context.response_text),
               "expected the parent's spec_file to be back in the actionable list after deletion, response was: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
