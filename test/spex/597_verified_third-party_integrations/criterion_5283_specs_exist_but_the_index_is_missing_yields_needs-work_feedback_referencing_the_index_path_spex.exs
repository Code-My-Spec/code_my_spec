defmodule CodeMySpecSpex.Story597.Criterion5283Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5283 — Specs exist but the index is missing yields needs-work feedback referencing the index path.

  When integration specs exist but the integrations index is absent,
  evaluate_task returns needs-work and the feedback names the
  expected index path.

  Surface: `evaluate_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the integration index plus per-spec verification" do
    scenario "Specs exist but the index is missing yields needs-work feedback referencing the index path" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "a verified twilio spec and verify script exist but the index does not",
             context do
        Fixtures.with_verified_integration_spec(context.environment, "twilio")
        Fixtures.with_verify_script(context.environment, "twilio")

        refute Fixtures.integration_index_exists?(context.environment),
               "expected the integration index to be absent"

        {:ok, context}
      end

      when_ "the agent calls evaluate_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool response indicates the task needs more work", context do
        body = response_text(context.response)

        assert body =~ ~r/needs work|incomplete|missing|invalid/i,
               "expected a needs-work response when the index is missing"

        {:ok, context}
      end

      and_ "the feedback references the integration index path", context do
        body = response_text(context.response)

        assert body =~ ".code_my_spec/integrations.md",
               "expected the feedback to name the integration index path"

        {:ok, context}
      end
    end
  end
end
