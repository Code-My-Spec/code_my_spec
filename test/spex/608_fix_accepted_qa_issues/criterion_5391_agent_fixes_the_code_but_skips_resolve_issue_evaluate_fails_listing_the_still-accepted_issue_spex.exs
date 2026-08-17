defmodule CodeMySpecSpex.Story608.Criterion5391Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 5391 — Agent fixes the code but skips resolve_issue,
  evaluate fails listing the still-accepted issue.

  Rule 3 (failure path): when the agent forgets to call resolve_issue,
  evaluate_task surfaces the still-accepted issue with feedback that
  prompts the agent to call resolve_issue with the issue id and
  resolution.

  Surface: `evaluate_task` MCP tool against an active fix-issues task,
  with one accepted issue still in the DB.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Skipping resolve_issue blocks evaluate_task" do
    scenario "Agent fixes the code but skips resolve_issue, evaluate fails listing the still-accepted issue" do
      given_ "an accepted issue exists and was never resolved", context do
        issue =
          Fixtures.issue_fixture(context.scope, %{
            severity: :high,
            status: :accepted,
            title: "Unresolved accepted issue"
          })

        {:ok, Map.put(context, :issue, issue)}
      end

      given_ :fix_issues_task_started

      when_ "the agent calls evaluate_task on the active fix-issues task",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the evaluate response signals needs-work, not completion",
            context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work|not met/i,
               "expected evaluate to surface a needs-work signal, got: #{body}"

        refute body =~ ~r/passed|task completed/i,
               "expected evaluate to NOT report success, got: #{body}"

        {:ok, context}
      end

      then_ "the feedback names the unresolved-issue gap so the agent knows what to fix",
            context do
        body = response_text(context.evaluate_response)

        # The IssuesChecker reason ("N unresolved medium+ issues") is the
        # minimum-viable signal the agent uses to loop back to
        # resolve_issue. The fix prompt itself names the resolve_issue
        # tool, so the feedback only needs to surface the gap.
        assert body =~ ~r/unresolved/i,
               "expected feedback to describe the unresolved-issue gap, got: #{body}"

        {:ok, context}
      end
    end
  end
end
