defmodule CodeMySpecSpex.Story608.Criterion5393Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 5393 — A fix breaks an unrelated test, agent fixes the
  regression rather than tagging it pending or claiming completion.

  Rule 4 (failure path): the system surfaces a regression-aware
  directive in the fix-issues prompt. Agent behaviour ("agent fixes
  the regression in code, doesn't add @tag :pending") is not testable
  in a spec — but the prompt that drives that behaviour is.

  Surface: `start_task` for `issues_resolved`. Asserts the prompt
  explicitly forbids skipping or tagging tests pending and tells the
  agent to fix regressions in source code.

  NOTE: This spec drives implementation. The current
  FixIssues.command/2 prompt only says "Run tests after all fixes" —
  it does not forbid `@tag :pending` / `@tag :skip` or instruct the
  agent on regression handling. The implementation must add that
  guidance to satisfy this criterion. The orthogonal mechanism (adding
  `:tests` to FixIssues.analyzers/0 so the stop-hook pipeline blocks on
  failures) is covered by the existing 555 stop-hook integration
  specs.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prompt forbids tag-skip-style regression silencing" do
    scenario "A fix breaks an unrelated test, agent fixes the regression rather than tagging it pending or claiming completion" do
      given_ "an accepted issue exists so the fix prompt is non-empty",
             context do
        issue =
          Fixtures.issue_fixture(context.scope, %{
            severity: :high,
            status: :accepted,
            title: "Some accepted bug"
          })

        {:ok, Map.put(context, :issue, issue)}
      end

      given_ :fix_issues_task_started

      then_ "the prompt anchors regression handling in the playbook",
            context do
        prompt = context.prompt

        assert prompt =~ ~r/regression/i,
               "expected prompt to reference regression handling, got:\n#{prompt}"

        assert prompt =~ ~r/silencing|silence/i,
               "expected prompt to flag test silencing as a no-go, got:\n#{prompt}"

        assert prompt =~ "priv/knowledge/fix_issues/workflow.md",
               "expected prompt to point at the fix_issues playbook (the @tag :pending / @tag :skip prohibition lives there)"

        {:ok, context}
      end
    end
  end
end
