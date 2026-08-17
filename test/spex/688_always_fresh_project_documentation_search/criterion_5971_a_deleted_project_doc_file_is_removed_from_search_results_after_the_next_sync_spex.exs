defmodule CodeMySpecSpex.Story688.Criterion5971Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5971 — A deleted project doc file is removed from search
  results after the next sync.

  Same rule as 5969/5970 (the embedding store mirrors disk),
  exercised on the delete path: when a file is removed from disk and
  the watcher fires its per-file sync event, the embedding pipeline
  drops the stale chunks.

  Driven via `Fixtures.notify_file_changed/2` — the production
  surface is the file watcher firing per-file `sync_path` events.
  After delete, the same event fires; `sync_path` notices the path
  is missing and clears the embeddings.

  See `criterion_5969_*_spex.exs` for the test-infrastructure
  assumptions about the configurable embedding serving.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @rule_path ".code_my_spec/rules/legacy.md"
  @rule_content """
  # Legacy Rule

  Use the long-deprecated `legacy_widget_factory/1` helper for
  fixture construction. This is the only way to bootstrap a widget
  in pre-v2 codebases.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent does not see deleted project doc files in semantic search results" do
    scenario "a deleted rule file disappears from search after the watcher syncs the delete" do
      given_ "rules/legacy.md is embedded in the project doc store", context do
        :ok = Environments.write_file(context.environment, @rule_path, @rule_content)
        {:ok, _result} = Fixtures.notify_file_changed(context.scope, @rule_path)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "legacy_widget_factory helper", source: "rules", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "legacy.md",
               "Pre-condition failed: expected legacy.md to be embedded after first sync, got:\n#{body}"

        {:ok, context}
      end

      when_ "the agent deletes legacy.md and the watcher syncs the deletion", context do
        :ok = Environments.delete_file(context.environment, @rule_path)
        {:ok, _result} = Fixtures.notify_file_changed(context.scope, @rule_path)
        {:ok, context}
      end

      then_ "semantic_search no longer returns any chunk citing legacy.md", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "legacy_widget_factory helper", source: "rules", limit: 10},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        # Anchor: a search header rendered, so a "no legacy.md" result
        # is a real absence, not a swallowed error.
        assert body =~ "Search:"

        refute body =~ "legacy.md",
               "Expected legacy.md to be absent from search after delete + watcher sync, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
