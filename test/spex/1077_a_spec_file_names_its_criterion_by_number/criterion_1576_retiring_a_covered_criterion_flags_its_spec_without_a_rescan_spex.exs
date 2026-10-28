defmodule CodeMySpecSpex.Story1077.Criterion1576Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 1576 — Retiring a covered criterion flags its spec without a rescan.

  Covers Rule "A spec file naming a retired criterion covers nothing and says
  to delete it". Which criterion a spec covers is a join on the number it
  names, so retiring the criterion changes the answer with the file untouched.
  The retire result names the file for the agent to delete in its own copy.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "test/spex/story_a/a_thing_happens_spex.exs"

  spex "Retiring flags the spec at once", criterion: 1576 do
    scenario "a covered criterion is retired and its spec file is not touched" do
      given_ "a spec naming the criterion covers it", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            @path,
            CriterionScript.spex_naming(number)
          )

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

      then_ "the spec is reported as naming a retired criterion, to be deleted", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        row = "[data-test='file-row'][data-file-path='#{@path}']"

        assert has_element?(view, "#{row} [data-test='file-validity'][data-validity='invalid']"),
               "the spec names a retired criterion and should read as invalid without a rescan"

        reason = view |> element("#{row} [data-test='file-reason']") |> render()
        assert reason =~ ~r/retired/i, "Got: #{reason}"
        assert reason =~ ~r/delete/i, "Got: #{reason}"

        {:ok, context}
      end

      then_ "and the retire result names it for the agent to delete in its copy", context do
        assert context.retired.text =~ "- #{@path} (criterion #{context.number})",
               "retire_criterion did not name the spec:\n#{context.retired.text}"

        {:ok, context}
      end
    end
  end
end
