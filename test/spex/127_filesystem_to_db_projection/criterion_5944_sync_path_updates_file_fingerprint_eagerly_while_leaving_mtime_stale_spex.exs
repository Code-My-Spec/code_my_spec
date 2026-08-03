defmodule CodeMySpecSpex.Story127.Criterion5944Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5944 — sync_path updates File.fingerprint eagerly while
  leaving mtime stale.

  Covers Rule 8's content-edit half: after a file's content changes
  and sync runs, File.fingerprint reflects the new content. Out-of-band
  consumers compare the (now-updated) fingerprint against their own
  last-seen and detect the change.

  The watcher's sync_path-specific stale-mtime invariant lives at the
  unit-test layer; the user-observable consequence — that File.fingerprint
  on the row matches the SHA-256 of current on-disk content — is what
  this spec asserts through the Files page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @impl_path "lib/fingerprint_demo.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees File.fingerprint update when file content changes" do
    scenario "editing a file changes its fingerprint after sync" do
      given_ "the agent has written content A and the engineer has synced", context do
        :ok = Environments.write_file(context.environment, @impl_path, content_a())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "the projection shows the fingerprint of content A on the impl row",
             context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_path}\"] [data-fingerprint=\"#{sha256(content_a())}\"]"
               )

        {:ok, context}
      end

      when_ "the agent edits the file to content B and the engineer re-syncs",
            context do
        :ok = Environments.write_file(context.environment, @impl_path, content_b())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the impl row's fingerprint is now content B's, not content A's",
            context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_path}\"] [data-fingerprint=\"#{sha256(content_b())}\"]"
               )

        refute has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_path}\"] [data-fingerprint=\"#{sha256(content_a())}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp content_a do
    """
    defmodule FingerprintDemo do
      @moduledoc "v1"
    end
    """
  end

  defp content_b do
    """
    defmodule FingerprintDemo do
      @moduledoc "v2"
    end
    """
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
