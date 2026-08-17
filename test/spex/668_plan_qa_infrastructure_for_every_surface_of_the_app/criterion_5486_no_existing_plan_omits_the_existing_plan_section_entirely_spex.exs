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

      then_ "a prompt came back at all", context do
        # The contrast the refutes need: an errored or empty reply contains no
        # section header either, so "the optional section is absent" held for a
        # `start_task` that produced nothing. `StartTask` writes the task id
        # into a footer, so that is the cheapest evidence a prompt is a prompt.
        assert extract_task_id!(context.prompt),
               "expected start_task to return a prompt with its task id, got:\n#{context.prompt}"

        {:ok, context}
      end

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
