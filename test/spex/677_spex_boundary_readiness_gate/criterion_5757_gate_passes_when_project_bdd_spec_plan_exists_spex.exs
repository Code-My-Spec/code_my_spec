defmodule CodeMySpecSpex.Story677.Criterion5757Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5757 — Gate passes when project BDD spec plan exists.

  Rule: The agent writes a project-specific BDD spec plan into
  `.code_my_spec/knowledge/bdd/spex/` as part of this step.

  When all three other artifacts are in place AND at least one `.md`
  file exists under `.code_my_spec/knowledge/bdd/spex/`, `evaluate_task`
  on the active spex_boundary_ready task signals pass. The checker is
  satisfied with one project-specific doc — filename is the agent's
  choice.

  Surface: `EvaluateTask` MCP tool against an in-memory environment.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  alias CodeMySpecSpex.SpexBoundaryArtifactHelpers, as: Artifacts

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Gate passes when project BDD spec plan exists" do
    scenario "all four artifacts present, including a markdown file under bdd/spex/ → evaluator returns pass" do
      given_ "all four spex boundary artifacts exist, with the project BDD plan at index.md",
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

      then_ "the response signals pass and does not name the BDD plan as missing", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/SpexBoundaryReady: Passed/i,
               "expected pass response, got: #{text}"

        refute text =~ ~r/knowledge\/bdd\/spex\/.*missing|missing.*knowledge\/bdd\/spex/,
               "pass response should not flag the BDD plan as missing, got: #{text}"

        {:ok, context}
      end
    end
  end
end
