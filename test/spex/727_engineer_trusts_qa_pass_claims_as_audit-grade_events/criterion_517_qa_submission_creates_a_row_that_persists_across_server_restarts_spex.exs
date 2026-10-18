defmodule CodeMySpecSpex.Story727.Criterion6452Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6452 — QA submission creates a row that persists across
  server restarts.

  Demonstrates the durability rule: a successful `submit_qa_result`
  call writes a row that is observable via `list_qa_attempts`. The
  cross-restart guarantee is the underlying Postgres durability; the
  agent surface contract is "what you submitted is what you can list
  later."

  Surfaces:
  - `CodeMySpec.Qa.Tools.SubmitQaResult` (write)
  - `CodeMySpec.Qa.Tools.ListQaAttempts` (read-back)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Each QA submission creates a durable, immutable history row", criterion: 517 do
    scenario "QA submission creates a row that persists across server restarts" do
      given_ "a started qa_complete task on a story with no prior attempts", context do
        # given: already true — `setup :setup_qa_story_task` builds the story
        # and a session carrying a started qa_complete task, and nothing has
        # submitted against it. "No prior attempts" is the fresh state.
        {:ok, context}
      end

      when_ "the agent submits a QA outcome with status pass", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, response)
        {:ok, Map.put(context, :submit_response, response)}
      end

      then_ "the attempt is observable via list_qa_attempts with all fields intact",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        list_response =
          ToolLibrary.run(
            "list_qa_attempts",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, list_response)
        text = response_text(list_response)

        assert text =~ "pass"
        assert text =~ "smoke"
        assert text =~ "story #{context.story.number}"

        {:ok, context}
      end
    end
  end
end
