defmodule CodeMySpecSpex.Story1077.Criterion4671Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4671 — A spec with no criterion number is invalid.

  Covers Rule "A spec file that names no criterion is invalid and says how to
  fix it". Surface: the project's Files page, which shows each file's validity
  and why.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @path "test/spex/unnamed/a_spec_that_names_nothing_spex.exs"

  spex "A spec must name its criterion" do
    scenario "a spec whose spex call names no criterion" do
      given_ "a spec file whose spex call names no criterion", context do
        :ok = Environments.write_file(context.environment, @path, CriterionScript.spex_naming(nil))
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
               "a spec that names no criterion should read as invalid"

        {:ok, Map.merge(context, %{view: view, row: row})}
      end

      and_ "the reason says to add criterion: <number> to the spex call", context do
        reason = context.view |> element("#{context.row} [data-test='file-reason']") |> render()

        assert reason =~ "criterion:",
               "the reason should tell the agent to add `criterion: <number>` to the spex call. Got: #{reason}"

        {:ok, context}
      end
    end
  end
end
