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

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the integration index plus per-spec verification", criterion: 239 do
    scenario "Spec missing the verified status yields needs-work naming the spec" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.execution_context)
        Fixtures.with_baseline_project(context.execution_context)
        {:ok, context}
      end

      given_ :qa_integration_plan_task_started

      given_ "this copy reads the fixture's in-memory files", context do
        {:ok, HarnessHooks.serve_in_memory(context)}
      end

      given_ "a pending twilio spec, its verify script, and the index are in place", context do
        Fixtures.with_pending_integration_spec(context.execution_context, "twilio")
        Fixtures.with_verify_script(context.execution_context, "twilio")
        Fixtures.with_integration_index(context.execution_context, ["twilio"])
        {:ok, context}
      end

      given_ "the harness has scanned the working copy", context do
        Fixtures.scan_working_copy(context.scope)
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
end
