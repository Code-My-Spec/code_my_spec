defmodule CodeMySpecSpex.Story1077.Criterion4681Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4681 — The evaluator passes when the requirement is satisfied.

  Covers Rule "The write-specs task passes only when the story's specs
  exist". The other half of 4680: agreeing on "no" is not enough.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The evaluator and the requirement agree on full coverage", criterion: 1557 do
    scenario "every active criterion has a valid spec on this working copy" do
      given_ :synced_context_component

      given_ "a story with two criteria is linked to the component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Two things",
            description: "A story whose specs are written.",
            acceptance_criteria: ["The first thing happens", "The second thing happens"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "every active criterion has a valid spec on this working copy", context do
        for criterion <- context.story.criteria do
          :ok =
            Environments.write_file(
              context.environment,
              "test/spex/two_things/criterion_#{criterion.id}_spex.exs",
              CriterionScript.spex_naming(criterion.id, "Criterion#{criterion.id}")
            )
        end

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      when_ "the agent evaluates its write-specs task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the evaluation passes", context do
        assert context.text =~ ~r/Passed/i, "every criterion has a spec. Got:\n#{context.text}"
        {:ok, context}
      end

      and_ "bdd_specs_exist is satisfied", context do
        assert CriterionScript.specs_exist?(context.scope, context.story.number),
               "the requirement and the evaluator must give the same answer"

        {:ok, context}
      end
    end
  end
end
