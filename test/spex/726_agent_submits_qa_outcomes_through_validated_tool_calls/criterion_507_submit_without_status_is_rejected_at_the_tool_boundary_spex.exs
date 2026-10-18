defmodule CodeMySpecSpex.Story726.Criterion6442Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6442 — Submit without status is rejected at the tool
  boundary.

  Demonstrates the failure path of the boundary-validation rule: a
  payload missing the required `status` field is rejected with a
  structured error before any state mutation. No attempt is
  recorded.

  Surfaces:
  - `CodeMySpec.Qa.Tools.SubmitQaResult` (rejection)
  - `CodeMySpec.Qa.Tools.ListQaAttempts` (observe nothing
    was recorded)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The submit tool rejects malformed payloads with a structured error", criterion: 507 do
    scenario "Submit without status is rejected at the tool boundary" do
      given_ "a started qa_complete task", context do
        # given: already true — `setup :setup_qa_story_task` builds the project,
        # the story and a session carrying a started qa_complete task for it,
        # through `Fixtures.qa_story_task_fixture/2`. Every criterion in this
        # story needs exactly that, so it is scaffolding rather than subject.
        {:ok, context}
      end

      when_ "the agent calls submit_qa_result without a status field", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the tool returns a structured error naming the missing status field",
            context do
        assert match?({:error, _}, context.submit_response),
               "expected error response, got: #{inspect(context.submit_response)}"

        text = response_text(context.submit_response)

        assert text =~ ~r/status/i,
               "expected error to name the status field, got:\n#{text}"

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

        refute text =~ "smoke",
               "expected no attempt with our scenario marker; got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
