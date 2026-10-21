defmodule CodeMySpecSpex.Story1077.Criterion1576Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 1576 — Retiring a covered criterion flags its spec without a rescan.

  Covers Rule "A spec file naming a retired criterion covers nothing and says
  to delete it". Which criterion a spec covers is a join on the number it
  names, so retiring the criterion changes the answer with no rescan. Since issue
  73e302aa retiring also deletes the spec on its working copy: the retire result
  says so, and a copy that cannot be reached reports it as pending deletion and
  keeps the file flagged until a sweep removes it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "test/spex/story_a/a_thing_happens_spex.exs"

  spex "Retiring flags the spec at once", criterion: 1576 do
    scenario "a covered criterion is retired and its spec file is deleted and reported" do
      given_ "a spec naming the criterion covers it", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        :ok =
          Environments.write_file(context.environment, @path, CriterionScript.spex_naming(number))

        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.put(context, :number, number)}
      end

      when_ "the agent retires the criterion", context do
        result =
          CriterionScript.run(
            context.scope,
            "return retire_criterion({ criterion_number = #{context.number} })"
          )

        refute result.error?, "retire_criterion failed: #{result.text}"
        {:ok, Map.put(context, :retired, result)}
      end

      then_ "the retire result says the spec was deleted", context do
        assert context.retired.text =~ "Deleted spex #{@path}",
               "retire_criterion did not report deleting the spec:\n#{context.retired.text}"

        {:ok, context}
      end

      then_ "and it is gone from the files list, with nothing left to rescan", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        refute has_element?(view, "[data-test='file-row'][data-file-path='#{@path}']")

        {:ok, context}
      end
    end
  end
end
