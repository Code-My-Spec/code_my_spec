defmodule CodeMySpecSpex.Story726.Criterion6449Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6449 — Status pass satisfies qa_complete.

  Demonstrates the only-pass-satisfies rule on the happy side:
  submitting with status pass records the attempt AND satisfies
  the qa_complete requirement.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Only status pass satisfies qa_complete" do
    scenario "Status pass satisfies qa_complete" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits with status pass", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        refute response.isError
        {:ok, context}
      end

      then_ "qa_complete is satisfied for the story", context do
        # Observed through the public context boundary `Qa.complete?/2`,
        # which is what the requirement checker's :delegate config calls.
        # ListRequirements MCP wraps the same call but its graph filter
        # depends on a fully-synced project — out of scope for this spec's
        # task-only fixture.
        assert CodeMySpec.Qa.qa_complete?(context.scope, context.story.id),
               "expected Qa.complete? true after passing submit"

        {:ok, context}
      end
    end
  end
end
