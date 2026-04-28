defmodule CodeMySpecSpex.Story668.Criterion5486Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5486 — No existing plan omits the Existing Plan section
  entirely.

  Rule (failure path): when no plan exists yet, the prompt does not
  include an Existing Plan section header at all — the agent doesn't
  see contradictory "diff and patch" instructions when there's
  nothing to diff against.

  Surface: `start_task` for the `qa_setup` project requirement,
  against a clean in-memory environment with no plan.md.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup prompt omits the Existing Plan section when no plan is present" do
    scenario "No existing plan omits the Existing Plan section entirely" do
      given_ :qa_setup_task_started

      then_ "the prompt does not contain an Existing Plan H2", context do
        prompt = context.prompt

        refute prompt =~ "## Existing Plan",
               "expected prompt to omit `## Existing Plan` when no plan exists, got: #{prompt}"

        refute prompt =~ ~r/update rather than rewrite/i,
               "expected prompt to NOT instruct diff-and-patch when no plan exists, got: #{prompt}"

        {:ok, context}
      end
    end
  end
end
