defmodule CodeMySpecSpex.Story608.Criterion6522Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 6522 — Mixed-severity backlog: prompt counts med+ only,
  evaluate ignores lows.

  Rule (Three Amigos, 2026-05-23): the fix loop is gated by a minimum
  blocking severity (currently `:medium`). Accepted issues at `:medium`
  or above appear in the prompt count and block `evaluate_task`;
  accepted `:low` and `:info` issues are tracked but do not gate
  completion.

  Single end-to-end scenario:
  1. Seed 5 accepted issues across every severity.
  2. start_task → prompt reports a count of 3 (med+ only).
  3. Resolve the 3 med+ issues via `resolve_issue` MCP tool.
  4. evaluate_task → :valid (lows + infos still accepted don't gate).

  Surface: `start_task` for `issues_resolved` + `resolve_issue` +
  `evaluate_task` MCP tools.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ResolveIssue
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Med+ gates the fix loop; lows and infos are tracked but do not block" do
    scenario "Mixed-severity backlog: prompt counts med+, evaluate passes once med+ are resolved" do
      given_ "5 accepted issues, one at each severity", context do
        issues =
          for severity <- [:critical, :high, :medium, :low, :info] do
            Fixtures.issue_fixture(context.scope, %{
              severity: severity,
              status: :accepted,
              title: "Accepted #{severity} issue"
            })
          end

        med_plus = Enum.filter(issues, &(&1.severity in [:critical, :high, :medium]))

        {:ok, Map.merge(context, %{issues: issues, med_plus: med_plus})}
      end

      given_ :fix_issues_task_started

      then_ "the prompt reports a count of 3 (critical + high + medium)",
            context do
        assert context.prompt =~ ~r/\*\*3 accepted issue\(s\)\*\*/,
               "expected prompt to count med+ only (3 issues), got:\n#{context.prompt}"

        {:ok, context}
      end

      when_ "the agent resolves each med+ issue via the resolve_issue MCP tool",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        for issue <- context.med_plus do
          {:reply, _resp, _frame} =
            ResolveIssue.execute(
              %{
                issue_id: to_string(issue.id),
                resolution: "Spex resolution: fixed in test setup."
              },
              frame
            )
        end

        {:ok, context}
      end

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

      then_ "evaluate signals task completion (lows + infos still accepted do not gate)",
            context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed|task completed/i,
               "expected evaluate to mark task done with only lows/infos remaining, got:\n#{body}"

        refute body =~ ~r/needs work|not met|unresolved/i,
               "expected evaluate to NOT surface a needs-work signal, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
