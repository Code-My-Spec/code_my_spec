defmodule CodeMySpecSpex.Story689.Criterion5980Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5980 — Repeat sync with unchanged dependencies does no
  hex doc embedding work.

  Covers Rule "Packages whose compiled BEAM content is unchanged
  since the last sync are skipped."

  ## Observation surface

  Same as story 688's idempotency scenario: assert via the /files
  page sync result panel that `Changed files` reads zero on a no-op
  re-sync. With the projected hex docs sitting under
  `.code_my_spec/hex_docs/`, the existing fingerprint-diff
  `changed_paths` skip applies uniformly — there's no hex-specific
  bookkeeping to test, just that the same skip rule covers this
  corpus.

  See `criterion_5977_*_spex.exs` for the test-infrastructure
  assumptions.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @hex_doc_path ".code_my_spec/hex_docs/phoenix/phoenix.md"
  @hex_doc_content """
  # Phoenix

  Phoenix.Endpoint provides the HTTP entry point.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees no churn from re-syncing when no dependencies changed" do
    scenario "a second sync with no projection edits reports zero changed files" do
      given_ "the project has been synced once with phoenix's projected markdown present",
             context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @hex_doc_content)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      when_ "the engineer re-syncs without changing any installed dependency", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the sync result reports zero changed files and zero changed components",
            context do
        html = render(context.files_live)

        # Anchor: the success panel is present, so we're really reading
        # post-sync state and not a half-rendered page.
        assert html =~ "Changed files"
        assert html =~ "Changed components"

        assert html =~ ~r/Changed files[^0-9]+0[^0-9]/,
               "Expected Changed files count to be 0 on the second sync, but got:\n#{html}"

        assert html =~ ~r/Changed components[^0-9]+0[^0-9]/,
               "Expected Changed components count to be 0 on the second sync, but got:\n#{html}"

        {:ok, context}
      end
    end
  end
end
