defmodule CodeMySpecSpex.Story726.Criterion6487Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6487 — Submit with fail or partial status and empty issue_ids is rejected at the tool boundary.

  Enforces the findings-as-issues rule (rule aa9a29e6): a non-pass
  outcome with no linked issue_ids has nowhere for its findings to
  live, so the submit tool refuses the call. Pass with empty
  issue_ids remains allowed (clean pass, nothing to file).

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "Non-pass submissions must carry at least one issue id" do
    scenario "Submit with fail status and empty issue_ids is rejected at the tool boundary" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits status fail with no linked issue_ids", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "fail",
              scenarios: [%{name: "smoke", status: "fail", observation: "saw a defect"}],
              issue_ids: []
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the submit tool returns an error pointing at create_issue", context do
        assert context.response.isError,
               "expected submit_qa_result to reject fail with empty issue_ids"

        text = response_text(context.response)

        assert text =~ "issue_ids" or text =~ "create_issue",
               "expected error to mention issue_ids/create_issue, got:\n#{text}"

        {:ok, context}
      end
    end

    scenario "Submit with partial status and empty issue_ids is rejected at the tool boundary" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits status partial with no linked issue_ids", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "partial",
              scenarios: [%{name: "smoke", status: "partial", observation: "ran out of time"}],
              issue_ids: []
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the submit tool returns an error pointing at create_issue", context do
        assert context.response.isError,
               "expected submit_qa_result to reject partial with empty issue_ids"

        text = response_text(context.response)

        assert text =~ "issue_ids" or text =~ "create_issue",
               "expected error to mention issue_ids/create_issue, got:\n#{text}"

        {:ok, context}
      end
    end

    scenario "Pass with empty issue_ids remains allowed" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits status pass with no linked issue_ids", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [%{name: "smoke", status: "pass", observation: "clean run"}],
              issue_ids: []
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the submit tool returns success", context do
        refute context.response.isError,
               "expected pass with empty issue_ids to be accepted"

        # And an attempt to show for it. The refute alone holds for a reply
        # that carries no error and no attempt either — the rejection
        # scenarios above asserted both the error and its message, and this
        # one asserted half as much about the case that is supposed to work.
        assert extract_attempt_id!(context.response),
               "expected an accepted submit to record an attempt"

        {:ok, context}
      end
    end
  end
end
