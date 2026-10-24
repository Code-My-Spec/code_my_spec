defmodule CodeMySpecSpex.Story1077.Criterion4672Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4672 — A number the project does not have covers nothing.

  Covers Rule "A spec file naming a criterion the project does not have
  covers nothing". Surface: the Files page, and the story's requirement.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "test/spex/ghost/criterion_9999_spex.exs"

  spex "An unknown criterion number binds to nothing", criterion: 1548 do
    scenario "a spec naming criterion 9999 in a project without one" do
      given_ "the project has no criterion 9999", context do
        story =
          CriterionScript.create_story(context.scope, "A real story", ["A real thing happens"])

        {:ok, Map.put(context, :story, story)}
      end

      when_ "a spec naming criterion: 9999 syncs", context do
        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            @path,
            CriterionScript.spex_naming(9999)
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the file is invalid and covers no criterion", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        row = "[data-test='file-row'][data-file-path='#{@path}']"

        assert has_element?(view, "#{row} [data-test='file-validity'][data-validity='invalid']"),
               "a spec naming an unknown criterion should read as invalid"

        refute CriterionScript.specs_exist?(context.scope, context.story),
               "a spec naming 9999 must not cover the story's real criterion"

        {:ok, Map.merge(context, %{view: view, row: row})}
      end

      and_ "the reason names 9999 as unknown", context do
        reason = context.view |> element("#{context.row} [data-test='file-reason']") |> render()

        assert reason =~ "9999", "the reason should name criterion 9999. Got: #{reason}"

        {:ok, context}
      end
    end
  end
end
