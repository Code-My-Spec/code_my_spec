defmodule CodeMySpecSpex.Story689.Criterion5977Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5977 — A newly installed hex package becomes searchable
  after the next sync.

  Covers Rule "Hex doc embeddings reflect the project's compiled
  dependencies." Story 688 established that `.code_my_spec/spec/`,
  `.code_my_spec/rules/`, `.code_my_spec/knowledge/`, and
  `.code_my_spec/framework/` flow through FileSync into the embedding
  store. This story extends the same path to projected hex docs
  landing at `.code_my_spec/hex_docs/<package>/*.md`.

  ## Test infrastructure assumed by this spex

  Same as story 688: a `:test` embeddings backend is configured (see
  `config/test.exs` → `:embeddings_backend`), and `Embeddings.available?/0`
  honors it. The implementer wires up the FileSync classifier so
  files under `.code_my_spec/hex_docs/<package>/*.md` get a hex doc
  role and a `hexdocs:<package>` source string, then ride the same
  embedding hook every other doc role uses.

  Projection from compiled BEAMs to markdown is upstream of this
  spec — we treat that step as already-run by writing the projected
  file directly via `Environments.write_file/3`. The spec asserts
  only the agent-observable contract: once the markdown is on disk
  and sync runs, semantic_search finds it.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.TaskResponseHelpers

  @hex_doc_path ".code_my_spec/hex_docs/phoenix/phoenix.md"
  @hex_doc_content """
  # Phoenix

  The Phoenix.Endpoint module defines a Phoenix endpoint module which
  serves as the entry point for incoming HTTP requests. Use the
  `Phoenix.Endpoint.broadcast/3` function to publish to a topic.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent finds newly installed hex package documentation in semantic search" do
    scenario "a projected phoenix hex doc file becomes searchable after sync" do
      given_ "no `phoenix` hex doc content is embedded yet", context do
        refute Environments.file_exists?(context.environment, @hex_doc_path)
        {:ok, context}
      end

      when_ "phoenix's projected markdown lands and the engineer re-syncs", context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @hex_doc_content)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      then_ "semantic_search with source `hexdocs:phoenix` returns a chunk citing the projected file",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "Phoenix.Endpoint broadcast topic", source: "hexdocs:phoenix", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "phoenix.md",
               "Expected SemanticSearch to cite the projected phoenix file, got:\n#{body}"

        # Anchor: a search header rendered, so this is a real result,
        # not a swallowed error.
        assert body =~ "Search:"

        {:ok, context}
      end
    end
  end
end
