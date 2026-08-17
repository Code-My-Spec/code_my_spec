defmodule CodeMySpecSpex.Story726.Criterion6448Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6448 — Submit with scenarios as a single string is
  rejected.

  Demonstrates the structured-scenarios rule's failure path: when
  the agent tries to summarize all scenarios as a single string,
  the tool rejects the payload with a structured error naming the
  expected list-of-objects shape. No attempt is recorded.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (rejection)
  - `CodeMySpec.McpServers.Qa.Tools.ListQaAttempts` (observe
    nothing was recorded)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{ListQaAttempts, SubmitQaResult}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Scenarios must be structured; freeform strings are rejected" do
    scenario "Submit with scenarios as a single string is rejected" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent calls submit_qa_result with scenarios as a single string",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: "marker_freeform_string_scenarios all three passed",
              issue_ids: []
            },
            frame
          )

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the tool returns a structured error naming the expected shape", context do
        assert context.submit_response.isError,
               "expected error response, got: #{inspect(context.submit_response)}"

        text = response_text(context.submit_response)

        assert text =~ ~r/scenarios/i,
               "expected error to name the scenarios field, got:\n#{text}"

        {:ok, context}
      end

      and_ "no attempt record was created", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        refute text =~ "marker_freeform_string_scenarios",
               "expected no attempt with our freeform marker, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
