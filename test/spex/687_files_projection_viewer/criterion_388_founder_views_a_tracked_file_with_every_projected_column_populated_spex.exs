defmodule CodeMySpecSpex.Story687.Criterion5947Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5947 — A tracked file's row on the projection viewer exposes
  the columns a founder needs to debug filesystem-to-DB drift: path,
  role, validity, mtime, and the owning component's name.

  The implementation file `synced_context_component` writes is the anchor row —
  it has a component_id (ExampleContext) and ought to render every
  projected column.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Founder views a tracked file with every projected column populated", criterion: 388 do
    scenario "the implementation row carries path, role, validity, mtime, and a component link" do
      given_ :synced_context_component

      when_ "the founder opens the files page", context do
        {:ok, files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        {:ok, Map.merge(context, %{files_live: files_live, html: html})}
      end

      then_ "the implementation's path appears on the page", context do
        # Anchor: a literal path proves the page rendered with real rows.
        assert context.html =~ "lib/example_context.ex",
               "expected the implementation's path to appear as a row on the files page"

        {:ok, context}
      end

      then_ "the row exposes role, validity, and mtime cells", context do
        row_selector =
          "[data-test='file-row'][data-file-path='lib/example_context.ex']"

        assert has_element?(context.files_live, "#{row_selector} [data-test='file-role']"),
               "expected the row to carry [data-test='file-role']"

        assert has_element?(context.files_live, "#{row_selector} [data-test='file-validity']"),
               "expected the row to carry [data-test='file-validity']"

        assert has_element?(context.files_live, "#{row_selector} [data-test='file-mtime']"),
               "expected the row to carry [data-test='file-mtime']"

        {:ok, context}
      end

      then_ "the row names the owning component", context do
        row_selector =
          "[data-test='file-row'][data-file-path='lib/example_context.ex']"

        assert has_element?(
                 context.files_live,
                 "#{row_selector} [data-test='file-component']",
                 "ExampleContext"
               ),
               "expected the row to show the owning component's name, ExampleContext"

        {:ok, context}
      end
    end
  end
end
