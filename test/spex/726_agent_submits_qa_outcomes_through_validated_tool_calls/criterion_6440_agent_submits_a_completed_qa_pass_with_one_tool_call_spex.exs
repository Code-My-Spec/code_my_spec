defmodule CodeMySpecSpex.Story726.Criterion6440Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6440 — Agent submits a completed QA pass with one tool
  call.

  Demonstrates the single-call contract: one `submit_qa_result`
  invocation with task_id + status + scenarios + issue_ids creates
  the attempt and satisfies `qa_complete`. No file writes; no
  evaluate_task; no rename dance.

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

  spex "Agent submits a QA outcome through a single MCP tool call" do
    scenario "Agent submits a completed QA pass with one tool call" do
      given_ "a started qa_complete task for a story", context do
        # given: already true — `setup :setup_qa_story_task` builds the project,
        # the story and a session carrying a started qa_complete task for it,
        # through `Fixtures.qa_story_task_fixture/2`. Every criterion in this
        # story needs exactly that, so it is scaffolding rather than subject.
        {:ok, context}
      end

      when_ "the agent calls submit_qa_result with task_id, status, scenarios, and one issue_id",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [
                %{name: "happy", status: "pass", observation: "all good"},
                %{name: "boundary", status: "pass", observation: "boundary held"}
              ],
              issue_ids: [Ecto.UUID.generate()]
            },
            frame
          )

        refute response.isError
        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the response includes the new attempt id and qa_complete is satisfied",
            context do
        text = response_text(context.submit_response)

        assert text =~ ~r/attempt[_ ]id/i,
               "expected attempt id in response, got:\n#{text}"

        # qa_complete is observed via list_requirements — the agent-facing
        # MCP surface for requirement satisfaction.
        qa_text = satisfied_qa_complete_text(context.scope)

        assert qa_text =~ context.story.title,
               "expected qa_complete satisfied for story #{context.story.title}, got:\n#{qa_text}"

        {:ok, context}
      end
    end
  end
end
