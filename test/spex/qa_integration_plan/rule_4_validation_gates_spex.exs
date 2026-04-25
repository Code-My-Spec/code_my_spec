defmodule CodeMySpecSpex.QaIntegrationPlan.Rule4ValidationGatesSpex do
  @moduledoc """
  Story: Verified third-party integrations
  Rule 4 — Validation gates on the integration index plus per-spec verification.

  `evaluate/2` is a state machine across five branches:

  1. No specs at all → :valid (empty pipeline)
  2. Specs exist + index missing → :invalid (feedback names index path)
  3. Specs exist + spec missing Verify Script section → :invalid (names the spec)
  4. Specs exist + index present + every spec verified → :valid
  5. Specs exist + spec lacking verified status → :invalid (names the spec)

  Surface: `evaluate_task` MCP tool. We dispatch through the custom
  `QaIntegrationPlan.evaluate/2` (registered in `Evaluator`).
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the integration index plus per-spec verification" do
    scenario "No integration specs and no index passes evaluation as the empty-pipeline path" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "no integration specs and no index exist", context do
        refute Fixtures.integration_spec_exists?(context.environment, "twilio")
        refute Fixtures.integration_index_exists?(context.environment)
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
               "expected the empty pipeline to clear the requirement"

        {:ok, context}
      end
    end

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

    scenario "A spec without a Verify Script section yields needs-work naming the spec" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "a twilio spec exists without a Verify Script section, plus the index", context do
        Fixtures.with_integration_spec_missing_verify_script(context.environment, "twilio")
        Fixtures.with_integration_index(context.environment, ["twilio"])
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

        assert body =~ ~r/needs work|incomplete|invalid|no verify script/i,
               "expected a needs-work response when the verify script is missing"

        {:ok, context}
      end

      and_ "the feedback names the offending twilio spec", context do
        body = response_text(context.response)

        assert body =~ "twilio",
               "expected the feedback to name the offending integration spec"

        {:ok, context}
      end
    end

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

    scenario "Spec missing the verified status yields needs-work naming the spec" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "a pending twilio spec, its verify script, and the index are in place", context do
        Fixtures.with_pending_integration_spec(context.environment, "twilio")
        Fixtures.with_verify_script(context.environment, "twilio")
        Fixtures.with_integration_index(context.environment, ["twilio"])
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

        assert body =~ ~r/needs work|incomplete|not yet verified|invalid/i,
               "expected a needs-work response when status is pending"

        {:ok, context}
      end

      and_ "the feedback names twilio as not yet verified", context do
        body = response_text(context.response)

        assert body =~ "twilio",
               "expected the feedback to name the offending integration spec"

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
