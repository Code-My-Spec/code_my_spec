defmodule CodeMySpecSpex.Story597.Criterion5285Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5285 — Verified spec plus index passes evaluation.

  A fully verified integration (spec + verify script + verified status
  + integration index) clears the requirement.

  Surface: `evaluate_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the integration index plus per-spec verification" do
    scenario "Verified spec plus index passes evaluation" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "a fully verified twilio integration is in place", context do
        Fixtures.with_verified_integration(context.environment, "twilio")

        assert Fixtures.integration_spec_exists?(context.environment, "twilio")
        assert Fixtures.verify_script_exists?(context.environment, "twilio")
        assert Fixtures.integration_index_exists?(context.environment)

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

      then_ "the tool response indicates the task passed", context do
        body = response_text(context.response)

        refute body =~ ~r/needs work|incomplete/i,
               "expected a passing response, not a needs-work response"

        assert body =~ ~r/passed|completed|satisfied|valid/i,
               "expected a verified spec plus index to clear the requirement"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
