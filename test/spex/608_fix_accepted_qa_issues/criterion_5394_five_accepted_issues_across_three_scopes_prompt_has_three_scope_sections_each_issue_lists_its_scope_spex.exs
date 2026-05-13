defmodule CodeMySpecSpex.Story608.Criterion5394Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 5394 — Five accepted issues across three scopes — prompt
  has three scope sections, each issue lists its scope.

  Rule 2: the fix prompt surfaces each issue's scope (`app` | `qa` |
  `docs`) and groups issues by scope, so the agent sees which layer to
  fix in before editing.

  Surface: `start_task` for the `issues_resolved` project requirement.
  Asserts on the `command/2` output — issues grouped by scope into
  "## Scope: ..." sections, and each issue block includes a "Scope: ..."
  line. No agent-behavior validation; just the prompt structure.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prompt surfaces and groups by scope" do
    scenario "Five accepted issues across three scopes — prompt has three scope sections, each issue lists its scope" do
      given_ "the project has 5 accepted issues — 3 :app, 1 :qa, 1 :docs",
             context do
        scope = context.scope

        app_issues =
          for n <- 1..3 do
            Fixtures.issue_fixture(scope, %{
              severity: :high,
              status: :accepted,
              scope: :app,
              title: "App issue #{n}"
            })
          end

        qa_issue =
          Fixtures.issue_fixture(scope, %{
            severity: :high,
            status: :accepted,
            scope: :qa,
            title: "QA seed missing fixture user"
          })

        docs_issue =
          Fixtures.issue_fixture(scope, %{
            severity: :high,
            status: :accepted,
            scope: :docs,
            title: "Spec docs out of date"
          })

        {:ok,
         Map.merge(context, %{
           app_issues: app_issues,
           qa_issue: qa_issue,
           docs_issue: docs_issue
         })}
      end

      given_ :fix_issues_task_started

      then_ "the prompt has a section header for each scope present", context do
        prompt = context.prompt

        assert prompt =~ "## Scope: app",
               "expected an app scope section header, got:\n#{prompt}"

        assert prompt =~ "## Scope: qa",
               "expected a qa scope section header, got:\n#{prompt}"

        assert prompt =~ "## Scope: docs",
               "expected a docs scope section header, got:\n#{prompt}"

        {:ok, context}
      end

      then_ "each issue block includes its declared scope", context do
        prompt = context.prompt
        all_issues = context.app_issues ++ [context.qa_issue, context.docs_issue]

        for issue <- all_issues do
          # Each issue's individual block lists "Scope: <scope>" so the
          # agent doesn't have to scan upward to find the section.
          assert prompt =~ "**Scope:** #{issue.scope}",
                 "expected issue #{issue.id} block to surface its scope (#{issue.scope}), got:\n#{prompt}"
        end

        {:ok, context}
      end
    end
  end
end
