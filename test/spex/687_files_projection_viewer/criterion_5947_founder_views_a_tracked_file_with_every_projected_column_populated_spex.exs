defmodule CodeMySpecSpex.Story687.Criterion5947Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5947 — A tracked file's row on the projection viewer exposes
  the columns a founder needs to debug filesystem-to-DB drift: path,
  role, validity, mtime, and a link to the owning component.

  The spec file `synced_context_component` writes is the anchor row —
  it has a component_id (ExampleContext) and ought to render every
  projected column.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Founder views a tracked file with every projected column populated" do
    scenario "the spec file row carries path, role, validity, mtime, and a component link" do
      given_ :synced_context_component

      when_ "the founder opens the files page", context do
        {:ok, files_live, html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        {:ok, Map.merge(context, %{files_live: files_live, html: html})}
      end

      then_ "the spec file's path appears on the page", context do
        # Anchor: a literal path proves the page rendered with real rows.
        assert context.html =~ ".code_my_spec/spec/example_context.spec.md",
               "expected the spec file's path to appear as a row on the files page"

        {:ok, context}
      end

      then_ "the spec row exposes role, validity, and mtime cells", context do
        row_selector =
          "[data-test='file-row'][data-file-path*='example_context.spec.md']"

        assert has_element?(context.files_live, "#{row_selector} [data-test='file-role']"),
               "expected the spec row to carry [data-test='file-role']"

        assert has_element?(context.files_live, "#{row_selector} [data-test='file-validity']"),
               "expected the spec row to carry [data-test='file-validity']"

        assert has_element?(context.files_live, "#{row_selector} [data-test='file-mtime']"),
               "expected the spec row to carry [data-test='file-mtime']"

        {:ok, context}
      end

      then_ "the spec row links to the owning component", context do
        row_selector =
          "[data-test='file-row'][data-file-path*='example_context.spec.md']"

        assert has_element?(
                 context.files_live,
                 "#{row_selector} [data-test='file-component-link']",
                 "ExampleContext"
               ),
               "expected the spec row to expose a component link pointing at ExampleContext"

        {:ok, context}
      end
    end
  end
end
