defmodule CodeMySpecSpex.Story127.Criterion5926Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5926 — Spec file with malformed structure is marked invalid
  with the parser error.

  Covers Rule "Validity is determined per file role" — failure path.
  A malformed spec (missing the H1 title) fails Documents validation;
  the File row shows up as invalid in the projection.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @broken_spec_path ".code_my_spec/spec/broken_context.spec.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees malformed specs flagged invalid in the projection" do
    scenario "spec missing the H1 title is marked invalid after sync" do
      given_ "the agent has written a spec file missing the required H1 title",
             context do
        :ok = Environments.write_file(context.environment, @broken_spec_path, broken_spec())
        {:ok, context}
      end

      when_ "the engineer triggers a sync from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the broken spec row shows the invalid badge", context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@broken_spec_path}\"] [data-validity='invalid']"
               )

        {:ok, context}
      end
    end
  end

  # No `# ModuleName` H1 → Documents.create_dynamic_document returns
  # `{:error, "Missing or invalid H1 title. ..."}`, which FileSync
  # captures into `validation_errors` and flips `valid` to false.
  defp broken_spec do
    """
    ## Type

    context

    A spec missing its H1 title — the document parser will reject this.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ## Dependencies

    - None

    ## Components

    None.
    """
  end
end
