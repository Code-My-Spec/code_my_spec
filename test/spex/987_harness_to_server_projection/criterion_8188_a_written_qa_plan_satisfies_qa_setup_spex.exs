defmodule CodeMySpecSpex.Story987.Criterion8188Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8188 — A written QA plan satisfies qa_setup.

  Covers Rule "Writing the artifact a requirement gates on satisfies that
  requirement, without any further action by the agent."

  `classify_qa/1` had clauses for `brief.md` and QA results and none for
  `plan.md`, so the plan never synced and `qa_setup` fell back to reading a disk
  the server does not have. Drill 9 wrote the plan, watched 137 files sync
  around it, and was told the plan was missing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent's QA plan satisfies the requirement that asked for it" do
    scenario "writing the QA plan satisfies qa_setup" do
      given_ "qa_setup is unsatisfied and no plan exists", context do
        refute Fixtures.requirement_satisfied?(
                 context.scope,
                 "qa_setup",
                 :project,
                 context.project.id
               )

        {:ok, context}
      end

      when_ "the agent writes the QA plan and the harness delivers its manifest", context do
        :ok = Environments.write_file(context.environment, Fixtures.qa_plan_path(), qa_plan())
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "qa_setup is satisfied", context do
        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "qa_setup",
                 :project,
                 context.project.id
               ),
               "the plan is on disk and synced; a requirement still asking for it " <>
                 "is asking the agent to write a file it already wrote"

        {:ok, context}
      end
    end
  end

  defp qa_plan do
    """
    # QA Plan

    ## App Overview

    Phoenix app on 4000 with session auth.

    ## Tools Registry

    ### curl

    `curl -s localhost:4000/health`

    ## Seed Strategy

    `mix run priv/repo/qa_seeds.exs` creates a signed-in user.
    """
  end
end
