defmodule CodeMySpecSpex.Story608.Criterion6523Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 6523 — Backlog discovery is JIT: prompt names list_issues
  + get_issue, embeds no issue bodies.

  Rule (Three Amigos, 2026-05-23): the fix prompt does not embed the
  issue backlog. It reports the count of accepted med+ issues and
  directs the agent to `list_issues` for discovery and `get_issue` for
  per-issue detail, so large backlogs never overflow the response
  window.

  This replaces the earlier "## Scope: ..." grouped-prompt contract.
  Scope-aware decisions still happen — but at the per-issue read step
  (the agent calls `get_issue`, which returns the scope), not via a
  prompt-embedded section.

  Surface: `start_task` for `issues_resolved` (FixIssues.command/2).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Fix prompt is JIT-discovery shaped, not backlog-embedded" do
    scenario "5 accepted issues across 3 scopes — prompt names the tools and embeds no bodies" do
      given_ "5 accepted med+ issues across :app, :qa, :docs", context do
        scope = context.scope

        app_issues =
          for n <- 1..3 do
            Fixtures.issue_fixture(scope, %{
              severity: :high,
              status: :accepted,
              scope: :app,
              title: "App issue #{n} — unique-#{System.unique_integer([:positive])}"
            })
          end

        qa_issue =
          Fixtures.issue_fixture(scope, %{
            severity: :high,
            status: :accepted,
            scope: :qa,
            title: "QA seed missing fixture user — unique-#{System.unique_integer([:positive])}"
          })

        docs_issue =
          Fixtures.issue_fixture(scope, %{
            severity: :high,
            status: :accepted,
            scope: :docs,
            title: "Spec docs out of date — unique-#{System.unique_integer([:positive])}"
          })

        {:ok,
         Map.merge(context, %{
           app_issues: app_issues,
           qa_issue: qa_issue,
           docs_issue: docs_issue
         })}
      end

      given_ :fix_issues_task_started

      then_ "the prompt names both list_issues and get_issue as MCP tools",
            context do
        assert context.prompt =~ "`list_issues`",
               "expected prompt to direct agent at `list_issues`, got:\n#{context.prompt}"

        assert context.prompt =~ "`get_issue`",
               "expected prompt to direct agent at `get_issue`, got:\n#{context.prompt}"

        {:ok, context}
      end

      then_ "the prompt embeds no per-issue bodies, ids, or scope sections",
            context do
        all_issues = context.app_issues ++ [context.qa_issue, context.docs_issue]

        for issue <- all_issues do
          refute context.prompt =~ issue.title,
                 "expected prompt NOT to embed issue title #{inspect(issue.title)}, got:\n#{context.prompt}"

          refute context.prompt =~ to_string(issue.id),
                 "expected prompt NOT to embed issue id #{inspect(issue.id)}, got:\n#{context.prompt}"
        end

        for header <- ["## Scope: app", "## Scope: qa", "## Scope: docs"] do
          refute context.prompt =~ header,
                 "expected prompt NOT to contain a `#{header}` section header (scope is read JIT via get_issue), got:\n#{context.prompt}"
        end

        {:ok, context}
      end

      then_ "the prompt reports the accepted med+ count", context do
        assert context.prompt =~ ~r/\*\*5 accepted issue\(s\)\*\*/,
               "expected prompt to report the count of 5 med+ accepted issues, got:\n#{context.prompt}"

        {:ok, context}
      end
    end
  end
end
