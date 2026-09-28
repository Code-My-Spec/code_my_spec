defmodule CodeMySpecSpex.Story1077.Criterion4680Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4680 — The evaluator refuses while a criterion is uncovered.

  Covers Rule "The write-specs task passes only when the story's specs
  exist". Issue 94327fe2: the evaluator checked a derived path on any working
  copy while the requirement checked this copy's bound files, so the task
  passed and was offered again, forever.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The evaluator and the requirement agree on an uncovered criterion", criterion: 1556 do
    scenario "one criterion has no valid spec on this working copy" do
      given_ :synced_context_component

      given_ "a story with two criteria is linked to the component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Two things",
            description: "A story whose specs are half written.",
            acceptance_criteria: ["The first thing happens", "The second thing happens"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "only the first criterion has a valid spec on this working copy", context do
        [first, second] = context.story.criteria

        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/two_things/criterion_#{first.id}_spex.exs",
            CriterionScript.spex_naming(first.id)
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.put(context, :uncovered, second.id)}
      end

      when_ "the agent evaluates its write-specs task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(%{task_id: context.task_id, session_id: context.session_id}, frame)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the evaluation fails and names the uncovered criterion", context do
        refute context.text =~ ~r/Passed/i,
               "a criterion has no spec, so the task must not pass. Got:\n#{context.text}"

        assert context.text =~ "Criterion #{context.uncovered}",
               "the feedback should name criterion #{context.uncovered}. Got:\n#{context.text}"

        {:ok, context}
      end

      and_ "the requirement is unsatisfied too", context do
        refute CriterionScript.specs_exist?(context.scope, to_string(context.story.id)),
               "the requirement and the evaluator must give the same answer"

        {:ok, context}
      end
    end
  end
end
