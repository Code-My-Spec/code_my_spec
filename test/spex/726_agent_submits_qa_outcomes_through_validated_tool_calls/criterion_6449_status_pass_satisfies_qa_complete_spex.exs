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

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Only status pass satisfies qa_complete" do
    scenario "Status pass satisfies qa_complete" do
      given_ "a started qa_complete task", context do
        # given: already true — `setup :setup_qa_story_task` builds the project,
        # the story and a session carrying a started qa_complete task for it,
        # through `Fixtures.qa_story_task_fixture/2`. Every criterion in this
        # story needs exactly that, so it is scaffolding rather than subject.
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
        # Observed through the list_requirements MCP surface —
        # the agent-facing view of requirement satisfaction.
        qa_text = satisfied_qa_complete_text(context.scope)

        assert qa_text =~ context.story.title,
               "expected qa_complete satisfied for story #{context.story.title}, got:\n#{qa_text}"

        {:ok, context}
      end
    end
  end
end
