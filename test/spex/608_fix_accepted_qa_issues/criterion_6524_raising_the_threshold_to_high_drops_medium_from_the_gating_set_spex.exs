defmodule CodeMySpecSpex.Story608.Criterion6524Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 6524 — Raising the threshold to `:high` drops `:medium`
  from the gating set.

  Rule (Three Amigos, 2026-05-23): the blocking severity threshold is
  operator-configurable per project via
  `ProjectConfiguration.fix_issues_min_severity` (default `:medium`).
  Changing it shifts both which issues appear in the fix prompt count
  and which issues block `evaluate_task`.

  Single end-to-end scenario:
  1. Set `fix_issues_min_severity = :high` on the project config.
  2. Seed 3 accepted issues — `:critical`, `:high`, `:medium`.
  3. start_task → prompt reports a count of 2 (critical + high) and
     names the configured threshold.
  4. Resolve the 2 high+ issues via `resolve_issue`.
  5. evaluate_task → `:valid` — the `:medium` issue still accepted
     doesn't gate because the threshold is `:high`.

  Surface: `ProjectConfiguration` update + `start_task` for
  `issues_resolved` + `resolve_issue` + `evaluate_task` MCP tools.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ResolveIssue
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Threshold is operator-configurable via ProjectConfiguration.fix_issues_min_severity" do
    scenario "Raising threshold to :high drops :medium from the gating set" do
      given_ "the project's fix_issues_min_severity is set to :high",
             context do
        {:ok, _config} =
          Fixtures.update_project_configuration(context.scope, %{fix_issues_min_severity: :high})

        {:ok, context}
      end

      given_ "3 accepted issues — one each at :critical, :high, :medium",
             context do
        issues =
          for severity <- [:critical, :high, :medium] do
            Fixtures.issue_fixture(context.scope, %{
              severity: severity,
              status: :accepted,
              title: "Accepted #{severity} issue"
            })
          end

        high_plus = Enum.filter(issues, &(&1.severity in [:critical, :high]))

        {:ok, Map.merge(context, %{issues: issues, high_plus: high_plus})}
      end

      given_ :fix_issues_task_started

      then_ "the prompt counts 2 high+ issues and names the configured threshold",
            context do
        assert context.prompt =~ ~r/\*\*2 accepted issue\(s\)\*\*/,
               "expected prompt to count high+ only (2 issues) under the :high threshold, got:\n#{context.prompt}"

        assert context.prompt =~ "(`high`)",
               "expected prompt to name the configured `:high` threshold, got:\n#{context.prompt}"

        {:ok, context}
      end

      when_ "the agent resolves the high+ issues via the resolve_issue MCP tool",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        for issue <- context.high_plus do
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

      then_ "evaluate marks the task done — the still-accepted :medium issue doesn't gate at :high threshold",
            context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed|task completed/i,
               "expected evaluate to mark task done since the :medium issue is below the :high threshold, got:\n#{body}"

        refute body =~ ~r/needs work|not met|unresolved/i,
               "expected evaluate to NOT surface a needs-work signal, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
