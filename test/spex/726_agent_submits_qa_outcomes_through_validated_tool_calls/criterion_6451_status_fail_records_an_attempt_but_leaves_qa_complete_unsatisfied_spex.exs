defmodule CodeMySpecSpex.Story726.Criterion6451Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6451 — Status fail records an attempt but leaves
  qa_complete unsatisfied.

  Demonstrates the only-pass-satisfies rule for the fail state:
  same shape as partial — the attempt persists in history but the
  requirement is still open.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  - `CodeMySpec.McpServers.Qa.Tools.ListQaAttempts`
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{ListQaAttempts, SubmitQaResult}
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Status fail is audit-grade but does not satisfy qa_complete" do
    scenario "Status fail records an attempt but leaves qa_complete unsatisfied" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits with status fail", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "fail",
              scenarios: [%{name: "smoke", status: "fail", observation: "blocking defect"}],
              issue_ids: []
            },
            frame
          )

        refute response.isError
        {:ok, context}
      end

      then_ "the attempt is in history with status fail", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        assert text =~ "fail"
        assert text =~ "blocking defect"

        {:ok, context}
      end

      and_ "qa_complete remains unsatisfied for the story", context do
        # Observed via Qa.complete?/2 — the public context function the
        # requirement checker delegates to.
        refute CodeMySpec.Qa.qa_complete?(context.scope, context.story.id),
               "expected Qa.complete? false after failing submit"

        {:ok, context}
      end
    end
  end
end
