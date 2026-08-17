defmodule CodeMySpecSpex.Story727.Criterion6453Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6453 — DB pass attempt satisfies qa_complete regardless
  of disk state.

  Demonstrates that `qa_complete` is satisfied by a passed DB attempt
  even when no `result_complete.md` exists on disk. The filesystem
  has no influence on the requirement decision.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (write)
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
    (observe satisfaction)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "qa_complete is satisfied by DB state, not file existence" do
    scenario "DB pass attempt satisfies qa_complete regardless of disk state" do
      given_ "a started qa_complete task and no result_complete.md on disk", context do
        {:ok, context}
      end

      when_ "the agent submits a QA outcome with status pass", context do
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

      then_ "qa_complete is satisfied for the story (DB-driven, no file gate)",
            context do
        # Observed via list_requirements — the agent-facing MCP surface for
        # requirement satisfaction. No file on disk was involved in the
        # assertion path.
        qa_text = satisfied_qa_complete_text(context.scope)

        assert qa_text =~ context.story.title,
               "expected qa_complete satisfied for story #{context.story.title} after passing submit, got:\n#{qa_text}"

        {:ok, context}
      end
    end
  end
end
