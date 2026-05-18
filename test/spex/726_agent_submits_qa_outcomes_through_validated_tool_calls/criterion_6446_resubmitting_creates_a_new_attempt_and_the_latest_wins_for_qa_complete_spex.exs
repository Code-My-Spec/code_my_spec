defmodule CodeMySpecSpex.Story726.Criterion6446Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6446 — Resubmitting creates a new attempt and the latest
  wins for qa_complete.

  Demonstrates the multi-submission rule: a partial submission
  followed by a pass submission results in two attempt rows in
  history, with qa_complete satisfied by the latest (pass).

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (x2)
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

  spex "Multiple submissions are allowed and the latest is canonical" do
    scenario "Resubmitting creates a new attempt and the latest wins for qa_complete" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits partial then later submits pass on the same task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, partial_response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "partial",
              scenarios: [%{name: "first_pass", status: "partial", observation: "incomplete"}],
              issue_ids: []
            },
            frame
          )

        refute partial_response.isError

        {:reply, pass_response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "second_pass", status: "pass", observation: "complete"}],
              issue_ids: []
            },
            frame
          )

        refute pass_response.isError
        {:ok, context}
      end

      then_ "both attempts are visible in history and qa_complete is satisfied", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        assert text =~ "first_pass"
        assert text =~ "second_pass"

        # Satisfaction is observed via list_requirements — the agent-facing
        # MCP surface for requirement satisfaction.
        qa_text = satisfied_qa_complete_text(context.scope)

        assert qa_text =~ context.story.title,
               "expected qa_complete satisfied for story #{context.story.title} after the latest (pass) submit, got:\n#{qa_text}"

        {:ok, context}
      end
    end
  end
end
