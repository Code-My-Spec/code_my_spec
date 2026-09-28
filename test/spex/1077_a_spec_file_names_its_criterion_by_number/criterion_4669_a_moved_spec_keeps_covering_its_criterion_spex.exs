defmodule CodeMySpecSpex.Story1077.Criterion4669Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4669 — A moved spec keeps covering its criterion.

  Covers Rule "A spec file covers the criterion it names, wherever the file
  sits". Directories and filenames are cosmetic.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @old_path "test/spex/1_old_home/a_task_is_captured_spex.exs"
  @new_path "test/spex/somewhere_else/renamed_spex.exs"

  spex "Moving a spec does not lose its criterion" do
    scenario "a spec moved to another directory still covers its criterion" do
      given_ "a spec naming the criterion covers it", context do
        story = CriterionScript.create_story(context.scope, "Capture a task", ["A task is captured"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        :ok = Environments.write_file(context.environment, @old_path, CriterionScript.spex_naming(number))
        Fixtures.deliver_manifest(context.scope)

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "the file is moved to another directory", context do
        :ok = Environments.delete_file(context.environment, @old_path)

        :ok =
          Environments.write_file(
            context.environment,
            @new_path,
            CriterionScript.spex_naming(context.number)
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the criterion is still covered by the moved file", context do
        text = CriterionScript.specs_requirement(context.scope, context.story)

        assert text =~ "**Status:** Satisfied",
               "the moved file still names criterion #{context.number}. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
