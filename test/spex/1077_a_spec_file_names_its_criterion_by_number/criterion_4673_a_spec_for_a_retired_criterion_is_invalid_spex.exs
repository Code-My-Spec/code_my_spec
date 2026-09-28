defmodule CodeMySpecSpex.Story1077.Criterion4673Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4673 — A spec for a retired criterion is invalid.

  Covers Rule "A spec file naming a retired criterion covers nothing and says
  to delete it". Deleting the file is left to the agent; the reason is how it
  finds out.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "test/spex/dropped/a_dropped_thing_spex.exs"

  spex "A spec for a retired criterion is flagged for deletion" do
    scenario "a spec naming a retired criterion syncs" do
      given_ "a criterion is retired", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing that was dropped"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        result =
          CriterionScript.run(context.scope, "return retire_criterion({ criterion_id = \"#{number}\" })")

        refute result.error?, "retire_criterion failed: #{result.text}"

        {:ok, Map.put(context, :number, number)}
      end

      and_ "a spec naming it is on disk", context do
        :ok = Environments.write_file(context.environment, @path, CriterionScript.spex_naming(context.number))
        {:ok, context}
      end

      when_ "the working copy syncs", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the file is invalid", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        row = "[data-test='file-row'][data-file-path='#{@path}']"

        assert has_element?(view, "#{row} [data-test='file-validity'][data-validity='invalid']"),
               "a spec naming a retired criterion should read as invalid"

        {:ok, Map.merge(context, %{view: view, row: row})}
      end

      and_ "the reason says the criterion is retired and the spec should be deleted", context do
        reason = context.view |> element("#{context.row} [data-test='file-reason']") |> render()

        assert reason =~ "#{context.number}", "the reason should name the criterion. Got: #{reason}"
        assert reason =~ ~r/retired/i, "the reason should say it is retired. Got: #{reason}"
        assert reason =~ ~r/delete/i, "the reason should say to delete the spec. Got: #{reason}"

        {:ok, context}
      end
    end
  end
end
