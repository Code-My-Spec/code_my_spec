defmodule CodeMySpecSpex.Story677.Criterion5755Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5755 — Gate passes when the fixtures bridge file exists.

  Rule: The fixtures bridge module at `test/support/fixtures/<app>_spex_fixtures.ex`
  must exist before any BDD spec is written.

  When all three other artifacts are in place AND the fixtures bridge
  file exists at the conventional path, `evaluate_task` on the active
  spex_boundary_ready task signals pass.

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

  spex "Gate passes when the fixtures bridge file exists" do
    scenario "all four artifacts present, including bridge → evaluator returns pass" do
      given_ "all four spex boundary artifacts exist with the bridge at the conventional path",
             context do
        :ok = Artifacts.write_baseline_artifacts(context.environment)
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

      then_ "the response signals pass and does not name the bridge as missing", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/SpexBoundaryReady: Passed/i,
               "expected pass response, got: #{text}"

        refute text =~ Artifacts.bridge_path(),
               "pass response should not name the bridge path, got: #{text}"

        {:ok, context}
      end
    end
  end
end
