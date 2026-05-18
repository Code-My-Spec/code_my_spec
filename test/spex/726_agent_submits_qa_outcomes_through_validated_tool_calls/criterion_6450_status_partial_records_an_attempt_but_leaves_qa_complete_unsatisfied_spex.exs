defmodule CodeMySpecSpex.Story726.Criterion6450Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6450 — Status partial records an attempt but leaves
  qa_complete unsatisfied.

  Demonstrates the only-pass-satisfies rule for the partial state:
  the attempt persists in history (audit-grade) but the requirement
  is still open.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  - `CodeMySpec.McpServers.Qa.Tools.ListQaAttempts`
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{ListQaAttempts, SubmitQaResult}
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, satisfied_qa_complete_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Status partial is audit-grade but does not satisfy qa_complete" do
    scenario "Status partial records an attempt but leaves qa_complete unsatisfied" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits with status partial", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "partial",
              scenarios: [%{name: "smoke", status: "partial", observation: "ran out of time"}],
              issue_ids: []
            },
            frame
          )

        refute response.isError
        {:ok, context}
      end

      then_ "the attempt is in history with status partial", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        assert text =~ "partial"
        assert text =~ "ran out of time"

        {:ok, context}
      end

      and_ "qa_complete remains unsatisfied for the story", context do
        # Observed via list_requirements — the agent-facing MCP surface for
        # requirement satisfaction. The story should NOT appear under the
        # satisfied=qa_complete filter.
        qa_text = satisfied_qa_complete_text(context.scope)

        refute qa_text =~ context.story.title,
               "expected qa_complete UNsatisfied for story #{context.story.title} after partial submit, got:\n#{qa_text}"

        {:ok, context}
      end
    end
  end
end
