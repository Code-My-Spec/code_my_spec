defmodule CodeMySpecSpex.Story561.Criterion5613Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5613 — A requirement with all three conditions met
  (satisfied_by present, unsatisfied, prereqs satisfied) appears in
  the actionable list.

  Surface: get_next_requirement MCP tool. Response is text — actionable
  requirements appear as `start_task with requirement_name=...,
  entity_type=..., entity_id=...` lines.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Actionable requirement appears when all conditions are met" do
    scenario "the response advertises at least one start_task call" do
      given_ :context_with_three_children

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response includes a start_task call signature for an actionable requirement",
            context do
        assert context.response_text =~ "start_task",
               "expected the response to advertise an actionable requirement via start_task"

        assert context.response_text =~ "requirement_name=",
               "expected the response to include requirement_name= in the start_task signature"

        assert context.response_text =~ "entity_id=",
               "expected the response to include entity_id= in the start_task signature"

        {:ok, context}
      end
    end
  end
end
