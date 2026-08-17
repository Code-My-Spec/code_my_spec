defmodule CodeMySpecSpex.Story677.Criterion5752Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5752 — Missing artifact is reported without inspecting
  other artifacts.

  Rule: The checker validates artifact existence only.

  When one of the four required artifacts is missing — here, the
  framework `spex_denied_calls.ex` — the evaluator response names
  exactly that path as the missing artifact and does NOT mention
  any of the other artifacts' contents or paths. The contract: the
  reason is a list of *what's missing*, not a list of *what was
  inspected*.

  Surface: `EvaluateTask` MCP tool.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  alias CodeMySpecSpex.SpexBoundaryArtifactHelpers, as: Artifacts

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Missing artifact is reported without inspecting other artifacts" do
    scenario "spex_denied_calls.ex missing, three other artifacts present → response names only the missing path" do
      given_ "three of four artifacts are present, only spex_denied_calls.ex is missing",
             context do
        :ok = Artifacts.write_baseline_artifacts(context.environment, skip: [:framework_denied])
        {:ok, context}
      end

      given_ :spex_boundary_ready_task_started

      when_ "the agent calls evaluate_task on the active task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response names spex_denied_calls.ex and no other artifact", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/SpexBoundaryReady: Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ Artifacts.denied_calls_path(),
               "expected response to name `#{Artifacts.denied_calls_path()}`, got: #{text}"

        refute text =~ Artifacts.no_send_path(),
               "response should not mention the other framework file when it exists"

        refute text =~ Artifacts.bridge_path(),
               "response should not mention the bridge when it exists"

        refute text =~ Artifacts.plan_path(),
               "response should not mention the plan when it exists"

        {:ok, context}
      end
    end
  end
end
