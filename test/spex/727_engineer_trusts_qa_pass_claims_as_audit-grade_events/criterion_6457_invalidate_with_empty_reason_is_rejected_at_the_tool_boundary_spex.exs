defmodule CodeMySpecSpex.Story727.Criterion6457Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6457 — Invalidate with empty reason is rejected at the
  tool boundary.

  Demonstrates the boundary validation on `invalidate_qa_attempt`:
  an empty reason is rejected with a structured error before any
  state mutation. No invalidation event is recorded and
  qa_complete stays satisfied.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed)
  - `CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt` (rejected)
  - `CodeMySpec.McpServers.Requirements.Tools.ListRequirements`
    (qa_complete unchanged)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{InvalidateQaAttempt, SubmitQaResult}
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Invalidate requires a non-empty reason" do
    scenario "Invalidate with empty reason is rejected at the tool boundary" do
      given_ "a story with a passed QA attempt", context do
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
        attempt_id = extract_attempt_id(response_text(submit_response))

        {:ok, Map.put(context, :attempt_id, attempt_id)}
      end

      when_ "the engineer calls invalidate_qa_attempt with an empty reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          InvalidateQaAttempt.execute(
            %{attempt_id: context.attempt_id, reason: ""},
            frame
          )

        {:ok, Map.put(context, :invalidate_response, response)}
      end

      then_ "the tool returns a structured error naming the missing reason",
            context do
        assert context.invalidate_response.isError,
               "expected error response, got: #{inspect(context.invalidate_response)}"

        text = response_text(context.invalidate_response)

        assert text =~ ~r/reason/i,
               "expected error to name the reason field, got:\n#{text}"

        {:ok, context}
      end

      and_ "qa_complete remains satisfied (no invalidation was recorded)", context do
        # Observed via Qa.qa_complete?/2 — the public context function the
        # requirement checker delegates to.
        assert CodeMySpec.Qa.qa_complete?(context.scope, context.story.id),
               "expected Qa.qa_complete? still true after a rejected empty-reason invalidate"

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
