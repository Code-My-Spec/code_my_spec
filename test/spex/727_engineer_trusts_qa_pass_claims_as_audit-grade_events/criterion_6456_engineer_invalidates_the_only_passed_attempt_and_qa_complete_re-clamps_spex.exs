defmodule CodeMySpecSpex.Story727.Criterion6456Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6456 — Engineer invalidates the only passed attempt and
  qa_complete re-clamps.

  Demonstrates the invalidation re-clamp: when an engineer
  invalidates the sole passed attempt on a story, the requirement
  re-opens. The original attempt is preserved (visible via
  list_qa_attempts); the invalidation event is audit-stamped with
  engineer id, timestamp, and reason.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed)
  - `CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt` (the action)
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
    (observe re-clamp)
  - `CodeMySpec.McpServers.Qa.Tools.ListQaAttempts` (observe
    preservation + invalidation metadata)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{InvalidateQaAttempt, ListQaAttempts, SubmitQaResult}
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1, satisfied_qa_complete_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Invalidating a pass with a reason re-clamps qa_complete and preserves the original" do
    scenario "Engineer invalidates the only passed attempt and qa_complete re-clamps" do
      given_ "a story with one passed QA attempt and qa_complete satisfied", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, submit_response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "ok"}],
              issue_ids: []
            },
            frame
          )

        refute submit_response.isError
        submit_text = response_text(submit_response)
        attempt_id = extract_attempt_id(submit_text)

        {:ok, Map.put(context, :attempt_id, attempt_id)}
      end

      when_ "the engineer invalidates the attempt with a reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, invalidate_response, _frame} =
          InvalidateQaAttempt.execute(
            %{attempt_id: context.attempt_id, reason: "Shallow probe; needs redo"},
            frame
          )

        refute invalidate_response.isError
        {:ok, context}
      end

      then_ "qa_complete is no longer satisfied for the story", context do
        # Observed via list_requirements — the agent-facing MCP surface for
        # requirement satisfaction. The story should NOT appear under the
        # satisfied=qa_complete filter after the only passed attempt is
        # invalidated.
        qa_text = satisfied_qa_complete_text(context.scope)

        refute qa_text =~ context.story.title,
               "expected qa_complete UNsatisfied for story #{context.story.title} after invalidating the only pass, got:\n#{qa_text}"

        {:ok, context}
      end

      and_ "the original attempt is preserved and the invalidation is audit-stamped",
           context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        assert text =~ context.attempt_id,
               "expected original attempt #{context.attempt_id} preserved in history"

        assert text =~ "invalidated",
               "expected attempt marked as invalidated"

        assert text =~ "Shallow probe; needs redo",
               "expected invalidation reason recorded"

        {:ok, context}
      end
    end
  end

  defp extract_attempt_id(text) do
    case Regex.run(~r/attempt[_ ]id[: ]+([a-f0-9-]+)/i, text) do
      [_, id] -> id
      _ -> raise "no attempt_id in submit response: #{text}"
    end
  end
end
