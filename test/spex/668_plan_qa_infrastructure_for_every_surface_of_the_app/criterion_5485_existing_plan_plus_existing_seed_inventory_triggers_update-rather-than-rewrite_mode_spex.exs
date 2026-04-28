defmodule CodeMySpecSpex.Story668.Criterion5485Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5485 — Existing plan plus existing seed inventory
  triggers update-rather-than-rewrite mode.

  Rule (happy path): when an existing plan and existing QA scripts
  are present, the prompt switches into "diff and patch" mode and
  surfaces the inventory so the agent can preserve working scripts
  and credentials rather than overwriting them.

  Surface: `start_task` for the `qa_setup` project requirement, with
  an existing plan, seed script, and helper script pre-seeded into
  the in-memory environment.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup prompt patches an existing plan rather than rewriting" do
    scenario "Existing plan plus existing seed inventory triggers update-rather-than-rewrite mode" do
      given_ "the project already has a qa plan, a qa seed script, and a helper script", context do
        env = context.environment

        :ok =
          Environments.write_file(env, ".code_my_spec/qa/plan.md", existing_plan())

        :ok =
          Environments.write_file(env, "priv/repo/qa_seeds.exs", "# qa seeds\n")

        :ok =
          Environments.write_file(
            env,
            ".code_my_spec/qa/scripts/authenticated_curl.sh",
            "#!/usr/bin/env bash\n"
          )

        {:ok, context}
      end

      given_ :qa_setup_task_started

      then_ "the prompt instructs the agent to update rather than rewrite the plan", context do
        prompt = context.prompt

        assert prompt =~ ~r/update rather than rewrite/i,
               "expected prompt to switch to update-mode, got: #{prompt}"

        assert prompt =~ ~r/preserve working scripts/i,
               "expected prompt to instruct preservation of working scripts, got: #{prompt}"

        {:ok, context}
      end

      then_ "the prompt's Inventory section lists the existing seed and helper scripts", context do
        prompt = context.prompt

        assert prompt =~ "priv/repo/qa_seeds.exs",
               "expected inventory to list the existing seed script, got: #{prompt}"

        assert prompt =~ "authenticated_curl.sh",
               "expected inventory to list the existing helper script, got: #{prompt}"

        {:ok, context}
      end
    end
  end

  defp existing_plan do
    """
    # QA Plan

    ## App Overview

    Existing app overview content.

    ## Tools Registry

    Existing tools registry content.

    ## Seed Strategy

    Existing seed strategy content.
    """
  end
end
