defmodule CodeMySpecSpex.Story689.Criterion5979Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5979 — An uninstalled hex package's docs are removed
  from search results.

  Same rule as 5977/5978 (hex doc embeddings reflect installed
  deps), exercised on the uninstall path: when a package's
  projected markdown is removed (because the package was
  uninstalled), the file sync pipeline drops its embeddings.

  See `criterion_5977_*_spex.exs` for the test-infrastructure
  assumptions.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.TaskResponseHelpers

  @hex_doc_path ".code_my_spec/hex_docs/phoenix/phoenix.md"
  @hex_doc_content """
  # Phoenix

  The Phoenix.Endpoint module defines an HTTP server entry point.
  Use `Phoenix.Endpoint.broadcast/3` to publish.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent does not see uninstalled hex packages in search results" do
    scenario "removing phoenix's projected markdown drops it from search after re-sync" do
      given_ "phoenix's projected markdown is on disk and the engineer has synced", context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @hex_doc_content)

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      when_ "phoenix is uninstalled (its projected markdown is deleted) and the engineer re-syncs",
            context do
        :ok = Environments.delete_file(context.environment, @hex_doc_path)

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      then_ "semantic_search with source `hexdocs:phoenix` returns no chunks citing phoenix.md",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "Phoenix Endpoint HTTP entry point", source: "hexdocs:phoenix", limit: 10},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        # Anchor: a search header rendered, so absence is a real
        # "no longer there," not a swallowed error.
        assert body =~ "Search:"

        refute body =~ "phoenix.md",
               "Expected phoenix.md to be absent from hexdocs:phoenix search after uninstall, got:\n#{body}"

        {:ok, context}
      end

      then_ "the all-packages hexdocs search no longer returns phoenix content either", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "Phoenix Endpoint HTTP entry point", source: "hexdocs", limit: 10},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "Search:"

        refute body =~ "phoenix.md",
               "Expected phoenix.md to be absent from hexdocs (all packages) search after uninstall, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
