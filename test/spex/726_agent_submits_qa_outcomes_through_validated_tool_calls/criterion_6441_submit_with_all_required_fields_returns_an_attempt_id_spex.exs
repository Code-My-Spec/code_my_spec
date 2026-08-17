defmodule CodeMySpecSpex.Story726.Criterion6441Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6441 — Submit with all required fields returns an attempt
  id.

  Demonstrates the happy path of the boundary-validation rule: a
  well-formed payload returns success with an attempt id in the
  response.

  Surface: `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The submit tool validates required fields at call time" do
    scenario "Submit with all required fields returns an attempt id" do
      given_ "a started qa_complete task", context do
        # given: already true — `setup :setup_qa_story_task` builds the project,
        # the story and a session carrying a started qa_complete task for it,
        # through `Fixtures.qa_story_task_fixture/2`. Every criterion in this
        # story needs exactly that, so it is scaffolding rather than subject.
        {:ok, context}
      end

      when_ "the agent calls submit_qa_result with task_id and status pass", context do
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

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the response is successful and contains an attempt id", context do
        refute context.submit_response.isError,
               "expected non-error response, got:\n#{inspect(context.submit_response)}"

        text = response_text(context.submit_response)

        assert text =~ ~r/attempt[_ ]id/i,
               "expected attempt id field name in response, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
