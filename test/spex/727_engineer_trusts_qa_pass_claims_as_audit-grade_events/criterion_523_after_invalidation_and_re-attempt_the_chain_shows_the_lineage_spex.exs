defmodule CodeMySpecSpex.Story727.Criterion6458Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6458 — After invalidation and re-attempt the chain shows
  the lineage.

  Demonstrates the parent_attempt_id chain: each new attempt links
  to the prior attempt on the same story. After two submissions,
  one invalidation, and a third submission, the chain is
  attempt #1 → attempt #2 (invalidated) → attempt #3, with the
  parent links observable via `list_qa_attempts`.

  Surfaces:
  - `CodeMySpec.Qa.Tools.SubmitQaResult` (write x3)
  - `CodeMySpec.Qa.Tools.InvalidateQaAttempt`
  - `CodeMySpec.Qa.Tools.ListQaAttempts` (observe chain)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Each attempt links to the prior attempt via parent_attempt_id", criterion: 523 do
    scenario "After invalidation and re-attempt the chain shows the lineage" do
      given_ "two QA attempts on a story where the second has been invalidated",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        attempt_ids =
          for marker <- ["first", "second"] do
            response =
              ToolLibrary.run(
                "submit_qa_result",
                %{
                  task_id: context.task_id,
                  status: "pass",
                  scenarios: [%{name: marker, status: "pass", observation: marker}],
                  issue_ids: []
                },
                Map.put(frame.assigns, :scope, frame.assigns.current_scope)
              )

            assert match?({:ok, _}, response)
            extract_attempt_id!(response_text(response))
          end

        [_first_id, second_id] = attempt_ids

        invalidate_response =
          ToolLibrary.run(
            "invalidate_qa_attempt",
            %{attempt_id: second_id, reason: "Discovered a missed probe"},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, invalidate_response)

        {:ok, Map.put(context, :prior_attempt_ids, attempt_ids)}
      end

      when_ "the agent submits a third attempt", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "submit_qa_result",
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "third", status: "pass", observation: "third"}],
              issue_ids: []
            },
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, response)
        third_id = extract_attempt_id!(response_text(response))

        {:ok, Map.put(context, :third_id, third_id)}
      end

      then_ "list_qa_attempts shows the chain attempt1 → attempt2 (invalidated) → attempt3",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_qa_attempts",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, response)
        text = response_text(response)

        [first_id, second_id] = context.prior_attempt_ids

        assert text =~ first_id, "expected first attempt in history"
        assert text =~ second_id, "expected second attempt in history"
        assert text =~ context.third_id, "expected third attempt in history"

        assert text =~ "invalidated", "expected second attempt marked invalidated"

        assert text =~ ~r/parent[_ ]attempt[_ ]id[: ]+#{Regex.escape(second_id)}/i,
               "expected third attempt's parent_attempt_id to point at second: #{text}"

        {:ok, context}
      end
    end
  end
end
