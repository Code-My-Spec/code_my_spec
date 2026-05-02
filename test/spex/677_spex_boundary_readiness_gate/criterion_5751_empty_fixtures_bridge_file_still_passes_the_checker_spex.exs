defmodule CodeMySpecSpex.Story677.Criterion5751Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5751 — Empty fixtures bridge file still passes the checker.

  Rule: The checker validates artifact existence only — no parsing,
  no boundary-deps verification, no content judgment.

  When all four spex boundary artifacts are present in the env — even
  if the fixtures bridge is just an empty `defmodule` — `evaluate_task`
  on the active spex_boundary_ready task signals pass. The checker
  does not crack open the bridge to verify boundary deps or imports.

  Surface: `EvaluateTask` MCP tool against an in-memory environment
  populated by `SpexBoundaryArtifactHelpers`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers
  alias CodeMySpecSpex.SpexBoundaryArtifactHelpers, as: Artifacts

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Empty fixtures bridge file still passes the checker" do
    scenario "all four artifacts present, bridge is an empty module → evaluator returns pass" do
      given_ "all four spex boundary artifacts exist with minimal content", context do
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

      then_ "the response signals pass for the SpexBoundaryReady task", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/SpexBoundaryReady: Passed/i,
               "expected pass response, got: #{text}"

        refute text =~ ~r/Needs work|missing/i,
               "pass response should not include failure feedback, got: #{text}"

        {:ok, context}
      end
    end
  end
end
