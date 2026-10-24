defmodule CodeMySpecSpex.Story687.Criterion5951Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5951 — A tracked file with no owning component renders on
  the projection viewer with an explicit unowned indicator, not as a
  blank or broken row.

  Project-scoped artifacts (CLAUDE.md, .credo.exs, mix.exs) are the
  natural unowned state: FileSync tracks them, ComponentSync ignores
  them (only spec/impl files derive components), and the File row
  lands with `component_id: nil`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.ExecutionContexts

  setup :register_log_in_setup_account
  setup :setup_active_project

  @orphan_path "CLAUDE.md"

  spex "Unowned files render with an explicit unowned indicator", criterion: 392 do
    scenario "a project-scoped artifact shows the unowned indicator instead of a blank component cell" do
      given_ :synced_context_component

      given_ "a CLAUDE.md is added and synced", context do
        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            @orphan_path,
            """
            # Project Context

            Notes the agent reads.
            """
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the founder opens the files page", context do
        {:ok, files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        {:ok, Map.merge(context, %{files_live: files_live, html: html})}
      end

      then_ "the orphan row carries the unowned indicator and no component link", context do
        # Anchor: the synced implementation proves the page rendered with content.
        assert context.html =~ "lib/example_context.ex",
               "expected the synced implementation to anchor the page"

        orphan_row_selector =
          "[data-test='file-row'][data-file-path='CLAUDE.md']"

        assert has_element?(
                 context.files_live,
                 "#{orphan_row_selector} [data-test='file-unowned']"
               ),
               "expected the CLAUDE.md row to expose [data-test='file-unowned'] in the component column"

        refute has_element?(
                 context.files_live,
                 "#{orphan_row_selector} [data-test='file-component']"
               ),
               "expected the CLAUDE.md row to omit the component label, since it has no owning component"

        {:ok, context}
      end
    end
  end
end
