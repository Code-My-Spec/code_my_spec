defmodule CodeMySpecSpex.Story1077.Criterion4674Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4674 — A second spec for one criterion is flagged.

  Covers Rule "A criterion is covered by one spec file". The file that got
  there first keeps the binding.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @first "test/spex/story_a/the_first_spex.exs"
  @second "test/spex/story_a/the_second_spex.exs"

  spex "One spec per criterion", criterion: 1550 do
    scenario "a second spec naming a covered criterion syncs" do
      given_ "a spec naming the criterion covers it", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        :ok = Environments.write_file(context.environment, @first, CriterionScript.spex_naming(number, "First"))
        Fixtures.deliver_manifest(context.scope)

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "a second spec naming the same criterion syncs", context do
        :ok =
          Environments.write_file(
            context.environment,
            @second,
            CriterionScript.spex_naming(context.number, "Second")
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the second file is invalid", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        row = "[data-test='file-row'][data-file-path='#{@second}']"

        assert has_element?(view, "#{row} [data-test='file-validity'][data-validity='invalid']"),
               "a second spec for one criterion should read as invalid"

        {:ok, Map.merge(context, %{view: view, row: row})}
      end

      and_ "the reason names the file that already covers it", context do
        reason = context.view |> element("#{context.row} [data-test='file-reason']") |> render()

        assert reason =~ @first, "the reason should name #{@first}. Got: #{reason}"

        {:ok, context}
      end

      and_ "the criterion stays covered by the first", context do
        assert CriterionScript.specs_exist?(context.scope, context.story),
               "the first spec still names the criterion, so the story's specs exist"

        {:ok, context}
      end
    end
  end
end
