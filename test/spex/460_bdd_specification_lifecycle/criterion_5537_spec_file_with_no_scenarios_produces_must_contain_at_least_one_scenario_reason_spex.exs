defmodule CodeMySpecSpex.Story460.Criterion5537Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5537 — Spec file with no scenarios produces the
  "Must contain at least one scenario" reason.

  When `evaluate_task` runs against a write_bdd_specs task whose
  story's spec file parses cleanly but contains zero scenarios, the
  evaluator returns "needs work" and the feedback includes the
  literal phrase "Must contain at least one scenario", along with
  the criterion's id and description.

  Surface: `EvaluateTask` MCP tool.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Spec file with zero scenarios → 'Must contain at least one scenario' feedback" do
    scenario "scenario-less spec → feedback names the criterion + the literal reason" do
      given_ :synced_context_component

      given_ "a story with one criterion is linked to the synced component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Empty-scenarios evaluation story",
            description: "Used for the empty-scenarios assertion.",
            acceptance_criteria: ["single acceptance criterion text"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "a spec file exists with a `spex` block but no scenarios", context do
        [criterion] = context.story.criteria
        spec_path = Fixtures.spec_file_path(context.story, criterion)
        :ok = Environments.write_file(context.environment, spec_path, scenarioless_spec_content())

        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the active task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response signals needs-work with the 'Must contain at least one scenario' reason",
            context do
        text = response_text(context.evaluate_response)
        [criterion] = context.story.criteria

        assert text =~ ~r/Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ "Must contain at least one scenario",
               "expected literal 'Must contain at least one scenario', got: #{text}"

        assert text =~ "Criterion #{criterion.id}",
               "expected feedback to name criterion #{criterion.id}, got: #{text}"

        {:ok, context}
      end
    end
  end

  defp scenarioless_spec_content do
    """
    defmodule MyAppSpex.ScenarioLessSpex do
      use MyAppSpex.Case

      spex "feature with no scenarios" do
      end
    end
    """
  end

end
