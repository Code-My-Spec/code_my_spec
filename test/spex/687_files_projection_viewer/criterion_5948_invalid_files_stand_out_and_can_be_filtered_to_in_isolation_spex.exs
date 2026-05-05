defmodule CodeMySpecSpex.Story687.Criterion5948Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5948 — Invalid files surface visually on the projection
  viewer and can be filtered to in isolation, so the founder can spot
  drift without scanning every row.

  Drift is established through the real surface: write a malformed
  context spec into the env, run sync via the existing /sync button.
  Spec validation fails for that file (the spec content is missing
  the required Type section), so the File row lands with valid: false
  and validation_errors populated.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @malformed_spec_path ".code_my_spec/spec/broken_context.spec.md"

  spex "Invalid files stand out and can be filtered" do
    scenario "an invalid file shows a status indicator and the invalid-only filter narrows to it" do
      given_ :synced_context_component

      given_ "a malformed context spec is added and synced", context do
        :ok =
          Environments.write_file(
            context.environment,
            @malformed_spec_path,
            """
            # BrokenContext

            no Type section, no Functions section — this should fail spec validation.
            """
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the founder opens the files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the malformed file's row carries an invalid status indicator", context do
        # Anchor: the valid spec we synced should still be on the page —
        # without this assertion an empty page would pass every refute below.
        assert render(context.files_live) =~ "example_context.spec.md",
               "expected the valid spec row to anchor the page"

        invalid_row_selector =
          "[data-test='file-row'][data-file-path*='broken_context.spec.md']"

        assert has_element?(
                 context.files_live,
                 "#{invalid_row_selector} [data-test='file-validity'][data-validity='invalid']"
               ),
               "expected the malformed spec row to carry [data-test='file-validity'][data-validity='invalid']"

        {:ok, context}
      end

      then_ "the invalid-only filter narrows the table to invalid rows", context do
        context.files_live
        |> element("[data-test='filter-invalid']")
        |> render_click()

        html = render(context.files_live)

        assert html =~ "broken_context.spec.md",
               "expected the malformed spec to remain visible under the invalid filter"

        refute html =~ "example_context.spec.md",
               "expected the valid spec to be filtered out under the invalid-only filter"

        {:ok, context}
      end
    end
  end
end
