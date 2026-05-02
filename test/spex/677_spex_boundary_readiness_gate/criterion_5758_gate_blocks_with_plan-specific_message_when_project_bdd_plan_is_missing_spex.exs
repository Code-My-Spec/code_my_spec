defmodule CodeMySpecSpex.Story677.Criterion5758Spex do
  @moduledoc """
  Story 677 — Spex boundary readiness gate
  Criterion 5758 — Gate blocks with plan-specific message when project
  BDD plan is missing.

  Rule: The agent writes a project-specific BDD spec plan into
  `.code_my_spec/knowledge/bdd/spex/` as part of this step.

  When the framework checks and fixtures bridge are in place but no
  `.md` file exists under `.code_my_spec/knowledge/bdd/spex/`,
  `evaluate_task` returns "Needs work" with the missing plan
  directory called out. The agent gets a precise pointer to a
  per-project doc gap, not a generic boundary-protection message.

  Surface: `EvaluateTask` MCP tool against an in-memory environment.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers
  alias CodeMySpecSpex.SpexBoundaryArtifactHelpers, as: Artifacts

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  @plan_dir ".code_my_spec/knowledge/bdd/spex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Gate blocks with plan-specific message when project BDD plan is missing" do
    scenario "framework checks and bridge present, no .md under bdd/spex/ → response names the plan directory" do
      given_ "framework checks and fixtures bridge are present, but no project BDD plan exists",
             context do
        :ok = Artifacts.write_baseline_artifacts(context.environment, skip: [:plan])
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

      then_ "the response names the missing project BDD plan directory", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/SpexBoundaryReady: Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ @plan_dir,
               "expected response to name `#{@plan_dir}` as the missing plan location, got: #{text}"

        refute text =~ Artifacts.bridge_path(),
               "bridge exists — response should not flag the bridge"

        refute text =~ Artifacts.denied_calls_path(),
               "framework files exist — response should not flag spex_denied_calls.ex"

        {:ok, context}
      end
    end
  end
end
