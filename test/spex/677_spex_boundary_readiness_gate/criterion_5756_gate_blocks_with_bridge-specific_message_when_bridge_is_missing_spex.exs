defmodule CodeMySpecSpex.Story677.Criterion5756Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5756 — Gate blocks with bridge-specific message when bridge
  is missing.

  Rule: The fixtures bridge module must exist before any BDD spec is
  written.

  When the framework checks and project BDD plan are in place but the
  fixtures bridge file is absent, `evaluate_task` returns "Needs work"
  with the specific bridge path called out as the missing artifact.
  The agent gets a precise pointer to fix.

  Surface: `EvaluateTask` MCP tool against an in-memory environment.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers
  alias CodeMySpecSpex.SpexBoundaryArtifactHelpers, as: Artifacts

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Gate blocks with bridge-specific message when bridge is missing" do
    scenario "framework checks and BDD plan present, bridge absent → response names the bridge path" do
      given_ "framework checks and project BDD plan are present, but the fixtures bridge is missing",
             context do
        :ok = Artifacts.write_baseline_artifacts(context.environment, skip: [:bridge])
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

      then_ "the response names the missing fixtures bridge path", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/SpexBoundaryReady: Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ Artifacts.bridge_path(),
               "expected response to name `#{Artifacts.bridge_path()}` as missing, got: #{text}"

        refute text =~ Artifacts.denied_calls_path(),
               "framework files exist — response should not flag spex_denied_calls.ex"

        refute text =~ Artifacts.no_send_path(),
               "framework files exist — response should not flag no_direct_send_in_spex.ex"

        {:ok, context}
      end
    end
  end
end
