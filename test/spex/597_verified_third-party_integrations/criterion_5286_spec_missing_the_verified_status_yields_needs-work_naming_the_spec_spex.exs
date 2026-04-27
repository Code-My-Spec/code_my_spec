defmodule CodeMySpecSpex.Story597.Criterion5286Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5286 — Spec missing the verified status yields needs-work naming the spec.

  A spec stuck at `pending` (verify script and index in place, but
  status not promoted) triggers needs-work, and the feedback names the
  offending spec as not yet verified.

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
