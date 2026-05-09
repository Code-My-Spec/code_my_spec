defmodule CodeMySpecSpex.Story689.Criterion5978Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5978 — An upgraded hex package's new version content
  replaces the old in search results.

  Same rule as 5977 (hex doc embeddings reflect installed deps),
  exercised on the upgrade path: when a package's projected markdown
  changes (because a new version shipped different docs), search
  surfaces the new wording and the old wording is gone.

  See `criterion_5977_*_spex.exs` for the test-infrastructure
  assumptions.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.TaskResponseHelpers

  @hex_doc_path ".code_my_spec/hex_docs/phoenix/phoenix.md"

  @v1_content """
  # Phoenix (v1)

  Use `Phoenix.Endpoint.broadcast/3` for synchronous publishing to
  a topic. This is the v1.x interface and it blocks until all
  subscribers have processed the message.
  """

  @v2_content """
  # Phoenix (v2)

  Use `Phoenix.Endpoint.broadcast/3` for fire-and-forget publishing
  to a topic. The v2.x interface dispatches asynchronously and
  returns immediately; subscribers consume in their own processes.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent sees upgraded hex package content in search after sync" do
    scenario "phoenix's projected markdown is replaced and search reflects the new content" do
      given_ "phoenix is embedded with v1 wording", context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @v1_content)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      when_ "the package is upgraded (v2 markdown lands) and the engineer re-syncs", context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @v2_content)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      then_ "search for the v2 wording returns the updated content from phoenix.md", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "fire and forget asynchronous dispatch", source: "hexdocs:phoenix", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "phoenix.md",
               "Expected SemanticSearch to cite phoenix.md, got:\n#{body}"

        assert body =~ "fire-and-forget",
               "Expected v2 content to surface, got:\n#{body}"

        {:ok, context}
      end

      then_ "search no longer returns the v1 wording", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "synchronous publishing v1.x interface blocks",
              source: "hexdocs:phoenix",
              limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        # Anchor: a search header rendered, so the v1 absence is a
        # real "no longer there," not a swallowed error.
        assert body =~ "Search:"

        refute body =~ "blocks until all\nsubscribers",
               "Expected v1's distinctive wording to be gone after upgrade + re-sync, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
