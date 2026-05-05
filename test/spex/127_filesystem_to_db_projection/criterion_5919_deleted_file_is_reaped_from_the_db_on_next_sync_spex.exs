defmodule CodeMySpecSpex.Story127.Criterion5919Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5919 — Deleted file is reaped from the DB on next sync.

  Covers Rule "Disk is the source of truth; the DB is a projection of it."
  Same observable contract as criterion 5933 (offline-deleted file reaped) —
  both surface as "file no longer appears in /files after re-sync."
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @spec_path ".code_my_spec/spec/example_context.spec.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees deleted files reaped from the projection on next sync" do
    scenario "deleted impl file disappears from /files after re-sync" do
      given_ :synced_context_component

      given_ "the impl file appears in the Files projection", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        assert has_element?(files_live, "[data-file-path=\"#{@impl_path}\"]")
        {:ok, context}
      end

      when_ "the agent deletes the impl from disk and the engineer re-syncs", context do
        :ok = Environments.delete_file(context.environment, @impl_path)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the impl file no longer appears in the projection", context do
        refute has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_path}\"]"
               )

        # Anchor: the spec file is still present, proving the table rendered.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"]"
               )

        {:ok, context}
      end
    end
  end
end
