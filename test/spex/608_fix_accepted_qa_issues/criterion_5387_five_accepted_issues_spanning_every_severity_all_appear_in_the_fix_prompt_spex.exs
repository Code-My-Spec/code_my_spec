defmodule CodeMySpecSpex.Story608.Criterion5387Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 5387 — Five accepted issues spanning every severity all
  appear in the fix prompt.

  Rule 1: the fix loop's working set is every accepted issue — no
  severity filter, no session-level threshold. Whatever made it past
  triage gets fixed.

  Surface: `start_task` for the `issues_resolved` project requirement.
  The fix prompt must enumerate every accepted issue regardless of
  severity.

  NOTE: This spec drives implementation. `FixIssues.command/2`
  currently filters at default `:medium`, so :low and :info issues are
  silently dropped. The implementation must remove the severity gate.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.IssuesFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Working set is every accepted issue, no severity filter" do
    scenario "Five accepted issues spanning every severity all appear in the fix prompt" do
      given_ "the project has 5 accepted issues, one at each severity",
             context do
        scope = context.scope

        issues =
          for severity <- [:critical, :high, :medium, :low, :info] do
            IssuesFixtures.issue_fixture(scope, %{
              severity: severity,
              status: :accepted,
              title: "Accepted #{severity} issue"
            })
          end

        {:ok, Map.put(context, :issues, issues)}
      end

      given_ :fix_issues_task_started

      then_ "the prompt lists every issue regardless of severity",
            context do
        prompt = context.prompt

        for issue <- context.issues do
          assert prompt =~ issue.id,
                 "expected prompt to include accepted #{issue.severity} issue #{issue.id}, got: #{prompt}"
        end

        {:ok, context}
      end
    end
  end
end
