defmodule CodeMySpecSpex.Story597.Criterion5282Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5282 — No integration specs and no index passes evaluation as the empty-pipeline path.

  Empty pipeline is a first-class happy path. A project with no
  third-party integrations clears the requirement.

  Surface: `evaluate_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the integration index plus per-spec verification", criterion: 235 do
    scenario "No integration specs and no index passes evaluation as the empty-pipeline path" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.execution_context)
        Fixtures.with_baseline_project(context.execution_context)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "no integration specs and no index exist", context do
        refute Fixtures.integration_spec_exists?(context.execution_context, "twilio")
        refute Fixtures.integration_index_exists?(context.execution_context)
        {:ok, context}
      end

      when_ "the agent calls evaluate_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool response indicates the task passed", context do
        body = response_text(context.response)

        refute body =~ ~r/needs work|incomplete/i,
               "expected a passing response, not a needs-work response"

        assert body =~ ~r/passed|completed|satisfied|valid/i,
               "expected the empty pipeline to clear the requirement"

        {:ok, context}
      end
    end
  end
end
