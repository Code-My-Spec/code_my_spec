defmodule CodeMySpecSpex.Story687.Criterion5952Spex do
  @moduledoc """
  Story 687 — Files Projection Viewer
  Criterion 5952 — The founder can trigger a re-sync from the files
  page itself; mutation delegates to the existing project sync flow
  and the rendered rows refresh in place — no full page reload.

  Drift is established mid-spec: a new module is written into the env
  AFTER the initial sync, so the file isn't yet a row. Clicking the
  page's sync action runs the same FileSync the existing /sync page
  drives, and the new row should appear in the same LiveView render
  without re-mounting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @drift_path "lib/post_drift_module.ex"

  spex "Founder triggers a re-sync from the files page and rows refresh in place" do
    scenario "a file written after the initial sync appears after clicking the page's sync action" do
      given_ :synced_context_component

      given_ "a new module is written to the env after the initial sync", context do
        :ok =
          Environments.write_file(
            context.environment,
            @drift_path,
            """
            defmodule PostDriftModule do
              @moduledoc false
            end
            """
          )

        {:ok, context}
      end

      when_ "the founder opens the files page and clicks Sync", context do
        {:ok, files_live, html_before} =
          live(context.conn, "/projects/#{context.project.name}/files")

        # Confirm drift exists at mount time — the new file hasn't been
        # synced yet, so it must not be on the page before the click.
        refute html_before =~ "post_drift_module.ex",
               "expected the post-drift module to be absent before sync runs"

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the new file appears in the same LiveView render", context do
        html_after = render(context.files_live)

        # Anchor: the synced spec must still be on the page — without it,
        # an empty render would pass every assertion below by accident.
        assert html_after =~ "example_context.spec.md",
               "expected the synced spec to remain visible after re-sync"

        assert html_after =~ "post_drift_module.ex",
               "expected the newly-synced file to appear in place after the sync action"

        {:ok, context}
      end
    end
  end
end
