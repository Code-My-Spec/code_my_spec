defmodule CodeMySpecSpex.Story689.Criterion5983Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5983 — Projected hex doc files appear in the Files
  projection after sync.

  Narrow watcher-coverage check: assert that the
  `.code_my_spec/hex_docs/<package>/*.md` path is in scope of
  FileSync's classifier — i.e., the file gets a recognized role and
  shows up as a row in the `/files` page after sync.

  This is intentionally weaker than the search scenarios (5977 / 5978
  / 5979). Those would also fail if the path weren't classified, but
  they also fail for many other reasons (embedding store, search
  query). When this scenario fails alone it points squarely at a
  missing classifier rule, which is the bug it's designed to catch.

  See `criterion_5977_*_spex.exs` for the test-infrastructure
  assumptions.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @hex_doc_path ".code_my_spec/hex_docs/phoenix/phoenix.md"
  @hex_doc_content """
  # Phoenix

  Phoenix.Endpoint provides the HTTP entry point.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "FileSync watches the hex doc projection directory" do
    scenario "a projected hex doc file shows up in the Files projection table after sync" do
      given_ "no `phoenix` hex doc files are tracked", context do
        refute Environments.file_exists?(context.environment, @hex_doc_path)
        {:ok, context}
      end

      when_ "phoenix's projected markdown lands and the engineer clicks sync", context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @hex_doc_content)

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the projected file appears as a row in the Files projection table", context do
        html = render(context.files_live)

        # The file path must be rendered in the table — proving the
        # classifier accepted the path and FileSync upserted a row.
        assert html =~ @hex_doc_path,
               "Expected #{@hex_doc_path} to appear in the Files projection. The classifier likely doesn't recognize `.code_my_spec/hex_docs/<package>/*.md` paths.\nRendered HTML:\n#{html}"

        # Anchor: the table actually rendered (not an empty page).
        assert html =~ "files-table"

        {:ok, context}
      end

      then_ "the file's role renders as a hex doc role, not a default fallback", context do
        # Anchor: a file row actually rendered, so the role check below
        # isn't vacuously true on an empty page.
        assert has_element?(context.files_live, "[data-test='file-row']")

        # The role column should NOT render an empty/unknown value.
        # If the classifier didn't pick this path up, the file
        # wouldn't have been upserted at all (caught by the previous
        # then_), but if the classifier returned `nil` and FileSync
        # routed through some default path, the role rendering would
        # be blank — guard against that with a positive check that
        # `data-test='file-role'` for this row is non-empty.
        refute has_element?(
                 context.files_live,
                 ~s|[data-test='file-row'] [data-test='file-role']:empty|
               ),
               "Expected the projected hex doc to have a non-empty role rendered in /files."

        {:ok, context}
      end
    end
  end
end
