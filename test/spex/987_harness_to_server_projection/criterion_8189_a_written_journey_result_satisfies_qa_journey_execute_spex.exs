defmodule CodeMySpecSpex.Story987.Criterion8189Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8189 — A written journey result satisfies qa_journey_execute.

  Covers Rule "Writing the artifact a requirement gates on satisfies that
  requirement, without any further action by the agent."

  `match_qa_result?/1` matched only `result_complete.md`, so `journey_result.md`
  was classified as nothing and never synced — the fifth artifact a requirement
  gated on that the classifier had never heard of.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An agent's journey result satisfies the requirement that asked for it" do
    scenario "writing the journey result satisfies qa_journey_execute" do
      given_ "a journey plan exists and no result does", context do
        :ok =
          Environments.write_file(
            context.environment,
            Fixtures.qa_journey_plan_path(),
            "# QA Journey Plan\n\n## Journeys\n\n### Capture\n\n1. Sign in\n2. Capture a task\n"
          )

        Fixtures.deliver_manifest(context.scope)

        refute Fixtures.requirement_satisfied?(
                 context.scope,
                 "qa_journey_execute",
                 :project,
                 context.project.id
               )

        {:ok, context}
      end

      when_ "the agent writes the journey result and the harness delivers its manifest",
            context do
        :ok =
          Environments.write_file(
            context.environment,
            Fixtures.qa_journey_result_path(),
            "# Journey Result\n\n## Capture\n\nRan it against the running server. Passed.\n"
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "qa_journey_execute is satisfied", context do
        assert Fixtures.requirement_satisfied?(
                 context.scope,
                 "qa_journey_execute",
                 :project,
                 context.project.id
               ),
               "the result is on disk and synced; the requirement asking for it " <>
                 "again is asking for work already done"

        {:ok, context}
      end
    end
  end
end
