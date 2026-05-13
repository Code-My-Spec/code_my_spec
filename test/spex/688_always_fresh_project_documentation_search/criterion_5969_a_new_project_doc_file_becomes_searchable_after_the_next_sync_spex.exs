defmodule CodeMySpecSpex.Story688.Criterion5969Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5969 — A new project doc file becomes searchable after the next sync.

  Covers Rule "Project documentation embeddings reflect the file sync
  pipeline's view of disk." A new spec/rule/knowledge file written to
  the working tree is picked up by the file watcher's per-file sync
  flow and becomes findable via the SemanticSearch MCP tool — without
  a separate manual embed step.

  ## Surface

  `CodeMySpecSpex.Fixtures.notify_file_changed/2` drives
  `ProjectSync.Sync.sync_path/2` — the same call the production file
  watcher invokes from an OS event. `sync_path/2` upserts the File
  row, refreshes the fingerprint, AND runs the embedding hook in one
  shot. Bulk `/files` UI syncs do NOT embed (engineer-driven embed is
  a separate `[data-test='embed-button']`); the watcher event is the
  always-fresh-search surface this story is about.

  ## Test infrastructure assumed by this spex

  Because the production embedding stack (Ortex + sqlite_vec) ships
  only with the CLI binary, this spec assumes:

  1. A deterministic test serving is configured for `:test` via
     `config :code_my_spec, :embedding_serving, <FakeServing>`.
  2. `Embeddings.available?/0` consults the configured serving (not
     just `Code.ensure_loaded?(OrtexServing)`) so the gate opens in
     test.
  3. The fake serving returns vectors deterministically derived from
     the embedded text — same text in → same vector out — so a query
     for the exact chunk content is the closest match.

  Without those, this spec will fail with `:embeddings_unavailable`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @spec_path ".code_my_spec/spec/widget.spec.md"
  @spec_content """
  # Widget Context

  The Widget context exposes `create_widget/2` which inserts a new
  widget for the given scope and returns `{:ok, widget}`.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent sees newly added project doc files in semantic search after sync" do
    scenario "a new spec file becomes searchable after the watcher syncs it" do
      given_ "no `widget.spec.md` exists in the project tree", context do
        refute Environments.file_exists?(context.environment, @spec_path)
        {:ok, context}
      end

      when_ "the agent writes the new spec file and the watcher syncs it", context do
        :ok = Environments.write_file(context.environment, @spec_path, @spec_content)
        {:ok, _result} = Fixtures.notify_file_changed(context.scope, @spec_path)
        {:ok, context}
      end

      then_ "semantic_search returns a chunk citing widget.spec.md", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "create_widget function", source: "spec", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "widget.spec.md",
               "Expected SemanticSearch to cite widget.spec.md after the watcher synced it, got:\n#{body}"

        # Anchor: response renders as a real search header, not an error.
        assert body =~ "Search:"
        {:ok, context}
      end
    end
  end
end
