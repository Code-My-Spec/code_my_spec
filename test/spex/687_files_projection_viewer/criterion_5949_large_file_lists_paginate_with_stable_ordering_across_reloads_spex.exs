defmodule CodeMySpecSpex.Story687.Criterion5949Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5949 — On a project with more tracked files than fit on a
  single page, the listing paginates with stable ordering — paging
  forward and reloading shows the same slice in the same order.

  Many files are introduced through the real surface: write 60 stray
  modules into the env, run sync via the existing /sync button. Each
  file becomes a File row, which is enough to overflow any reasonable
  page size.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @file_count 60

  spex "Large file lists paginate with stable ordering across reloads" do
    scenario "page 2 renders different rows than page 1 and the slice survives a reload" do
      given_ :synced_context_component

      given_ "many extra files are added and synced", context do
        for i <- 1..@file_count do
          :ok =
            Environments.write_file(
              context.environment,
              "lib/orphan_#{:io_lib.format("~3..0B", [i]) |> IO.iodata_to_binary()}.ex",
              """
              defmodule Orphan#{i} do
                @moduledoc false
              end
              """
            )
        end

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the founder opens the files page", context do
        {:ok, files_live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        {:ok, Map.merge(context, %{files_live: files_live, html: html})}
      end

      then_ "the first page renders a bounded number of rows alongside pagination controls",
            context do
        # Anchor: the page must render at least one file row.
        assert context.html =~ "data-test=\"file-row\"" or
                 context.html =~ "data-test='file-row'",
               "expected at least one file row to render on page 1"

        rendered_row_count =
          Regex.scan(~r/data-test=["']file-row["']/, context.html)
          |> length()

        assert rendered_row_count < @file_count,
               "expected page 1 to render fewer than #{@file_count} rows (pagination must be in play); got #{rendered_row_count}"

        assert has_element?(context.files_live, "[data-test='pagination']"),
               "expected [data-test='pagination'] controls to appear when more than one page exists"

        {:ok, context}
      end

      then_ "page 2 contains rows page 1 did not, and reloading page 2 shows the same slice",
            context do
        page_1_rows = extract_row_paths(context.html)

        {:ok, _page_2_live, page_2_html} =
          live(context.conn, "/app/projects/#{context.project.name}/files?page=2")

        page_2_rows_first = extract_row_paths(page_2_html)

        refute page_2_rows_first == [],
               "expected page 2 to render at least one row"

        assert MapSet.disjoint?(MapSet.new(page_1_rows), MapSet.new(page_2_rows_first)),
               "expected page 1 and page 2 to render disjoint row sets"

        # Reload page 2 in a fresh LiveView mount and compare.
        {:ok, _page_2_live_again, page_2_html_again} =
          live(context.conn, "/app/projects/#{context.project.name}/files?page=2")

        page_2_rows_again = extract_row_paths(page_2_html_again)

        assert page_2_rows_first == page_2_rows_again,
               "expected page 2 to render the same rows in the same order on reload"

        {:ok, context}
      end
    end
  end

  defp extract_row_paths(html) do
    Regex.scan(~r/data-file-path=["']([^"']+)["']/, html)
    |> Enum.map(fn [_, path] -> path end)
  end
end
