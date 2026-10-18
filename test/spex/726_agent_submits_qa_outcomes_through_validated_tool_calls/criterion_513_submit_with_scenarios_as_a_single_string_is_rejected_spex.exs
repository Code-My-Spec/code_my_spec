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
  - `CodeMySpec.Qa.Tools.SubmitQaResult` (rejection)
  - `CodeMySpec.Qa.Tools.ListQaAttempts` (observe
    nothing was recorded)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Scenarios must be structured; freeform strings are rejected", criterion: 513 do
    scenario "Submit with scenarios as a single string is rejected" do
      given_ "a started qa_complete task", context do
        # given: already true — `setup :setup_qa_story_task` builds the project,
        # the story and a session carrying a started qa_complete task for it,
        # through `Fixtures.qa_story_task_fixture/2`. Every criterion in this
        # story needs exactly that, so it is scaffolding rather than subject.
        {:ok, context}
      end

      when_ "the agent calls submit_qa_result with scenarios as a single string",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: "marker_freeform_string_scenarios all three passed",
              issue_ids: []
            },
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the tool returns a structured error naming the expected shape", context do
        assert match?({:error, _}, context.submit_response),
               "expected error response, got: #{inspect(context.submit_response)}"

        text = response_text(context.submit_response)

        assert text =~ ~r/scenarios/i,
               "expected error to name the scenarios field, got:\n#{text}"

        {:ok, context}
      end

      and_ "no attempt record was created", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        list_response =
          ToolLibrary.run(
            "list_qa_attempts",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, list_response)
        text = response_text(list_response)

        refute text =~ "marker_freeform_string_scenarios",
               "expected no attempt with our freeform marker, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
