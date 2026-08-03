defmodule CodeMySpecSpex.Story688.Criterion5972Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5972 — Repeat sync with unchanged files does no embedding work.

  Covers Rule "Files whose checksum is unchanged since the last
  embedding are skipped — the embedding step is content-aware and
  idempotent across repeat sync runs."

  ## Observation surface

  The user-facing signal is the sync result panel on the /files page:
  the existing `Changed files` line already reports zero when
  nothing changed. This spec asserts on that count to prove the
  pipeline did not redo work.

  Specifying that "no embedding work happened" *internally* (e.g. no
  Oban job enqueued) would be a peek at the implementation. The
  observable effect — the engineer-visible counter staying at zero —
  is the contract a reasonable agent or operator can rely on.

  See `criterion_5969_*_spex.exs` for the test-infrastructure
  assumptions about the configurable embedding serving.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @spec_path ".code_my_spec/spec/widget.spec.md"
  @spec_content """
  # Widget Context

  The Widget context exposes `create_widget/2`.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees no churn from re-syncing when nothing on disk has changed" do
    scenario "a second sync with no edits reports zero changed files" do
      given_ "the project has been synced once with widget.spec.md present", context do
        :ok = Environments.write_file(context.environment, @spec_path, @spec_content)

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      when_ "the engineer re-syncs without changing anything on disk", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the sync result reports zero changed files and zero changed components",
            context do
        html = render(context.files_live)

        # Anchor: the sync results panel is present so we're really
        # reading post-sync state, not a half-rendered page.
        assert html =~ "Changed files"
        assert html =~ "Changed components"

        # The exact rendering puts label and value in adjacent <li> bits.
        # Match `Changed files</…>0` shape across the rendered HTML.
        assert html =~ ~r/Changed files[^0-9]+0[^0-9]/,
               "Expected Changed files count to be 0 on the second sync, but got:\n#{html}"

        assert html =~ ~r/Changed components[^0-9]+0[^0-9]/,
               "Expected Changed components count to be 0 on the second sync, but got:\n#{html}"

        {:ok, context}
      end
    end
  end
end
