defmodule CodeMySpecSpex.Story1077.Criterion4668Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4668 — A spec naming its criterion covers it.

  Covers Rule "A spec file covers the criterion it names, wherever the file
  sits". The file says which criterion it is on its `spex` call; the harness
  reads that and the server binds it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A spec names the criterion it covers", criterion: 1544 do
    scenario "a spec whose spex call names the criterion covers it" do
      given_ "the story has a criterion", context do
        story = CriterionScript.create_story(context.scope, "Capture a task", ["A task is captured"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "the agent writes a spec whose spex call names that criterion", context do
        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/anywhere/a_task_is_captured_spex.exs",
            CriterionScript.spex_naming(context.number)
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the criterion is covered by that file", context do
        text = CriterionScript.specs_requirement(context.scope, context.story)

        assert text =~ "**Status:** Satisfied",
               "the spec names criterion #{context.number}, so the story's specs exist. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
