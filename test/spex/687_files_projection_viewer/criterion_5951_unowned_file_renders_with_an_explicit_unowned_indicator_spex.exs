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

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @orphan_path "CLAUDE.md"

  spex "Unowned files render with an explicit unowned indicator" do
    scenario "a project-scoped artifact shows the unowned indicator instead of a blank component cell" do
      given_ :synced_context_component

      given_ "a CLAUDE.md is added and synced", context do
        :ok =
          Environments.write_file(
            context.environment,
            @orphan_path,
            """
            # Project Context

            Notes the agent reads.
            """
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the founder opens the files page", context do
        {:ok, files_live, html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        {:ok, Map.merge(context, %{files_live: files_live, html: html})}
      end

      then_ "the orphan row carries the unowned indicator and no component link", context do
        # Anchor: the synced spec proves the page rendered with content.
        assert context.html =~ "example_context.spec.md",
               "expected the synced spec to anchor the page"

        orphan_row_selector =
          "[data-test='file-row'][data-file-path='CLAUDE.md']"

        assert has_element?(
                 context.files_live,
                 "#{orphan_row_selector} [data-test='file-unowned']"
               ),
               "expected the CLAUDE.md row to expose [data-test='file-unowned'] in the component column"

        refute has_element?(
                 context.files_live,
                 "#{orphan_row_selector} [data-test='file-component-link']"
               ),
               "expected the CLAUDE.md row to omit a component link, since it has no owning component"

        {:ok, context}
      end
    end
  end
end
