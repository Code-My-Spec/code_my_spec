defmodule CodeMySpecSpex.Story687.Criterion5948Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5948 — Invalid files surface visually on the projection
  viewer and can be filtered to in isolation, so the founder can spot
  drift without scanning every row.

  Drift is established through the real surface: write a malformed
  spex file into the env, run sync via the existing /sync button.
  The scan's spex check fails for that file (it names no criterion),
  so the File row lands with valid: false and its reason recorded.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.ExecutionContexts

  setup :register_log_in_setup_account
  setup :setup_active_project

  @malformed_spec_path "test/spex/1_broken/criterion_1_broken_spex.exs"

  spex "Invalid files stand out and can be filtered", criterion: 389 do
    scenario "an invalid file shows a status indicator and the invalid-only filter narrows to it" do
      given_ :synced_context_component

      given_ "a malformed spex file is added and synced", context do
        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            @malformed_spec_path,
            """
            defmodule Broken do
              # names no criterion, so it binds to nothing
            end
            """
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the founder opens the files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the malformed file's row carries an invalid status indicator", context do
        # Anchor: the valid implementation we synced should still be on the page —
        # without this assertion an empty page would pass every refute below.
        assert render(context.files_live) =~ "lib/example_context.ex",
               "expected the valid implementation row to anchor the page"

        invalid_row_selector =
          "[data-test='file-row'][data-file-path*='criterion_1_broken_spex.exs']"

        assert has_element?(
                 context.files_live,
                 "#{invalid_row_selector} [data-test='file-validity'][data-validity='invalid']"
               ),
               "expected the malformed spex row to carry [data-test='file-validity'][data-validity='invalid']"

        {:ok, context}
      end

      then_ "the invalid-only filter narrows the table to invalid rows", context do
        context.files_live
        |> element("[data-test='filter-invalid']")
        |> render_click()

        html = render(context.files_live)

        assert html =~ "criterion_1_broken_spex.exs",
               "expected the malformed spex to remain visible under the invalid filter"

        refute html =~ "lib/example_context.ex",
               "expected the valid implementation to be filtered out under the invalid-only filter"

        {:ok, context}
      end
    end
  end
end
