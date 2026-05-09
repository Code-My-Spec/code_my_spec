defmodule CodeMySpecSpex.Story688.Criterion5971Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5971 — A deleted project doc file is removed from search
  results after the next sync.

  Same rule as 5969/5970 (the embedding store mirrors disk),
  exercised on the delete path: when a file is removed from disk,
  the file sync pipeline drops its embeddings on the next run.

  See `criterion_5969_*_spex.exs` for the test-infrastructure
  assumptions about the configurable embedding serving.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
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
    scenario "a deleted rule file disappears from search after re-sync" do
      given_ "rules/legacy.md is embedded in the project doc store", context do
        :ok = Environments.write_file(context.environment, @rule_path, @rule_content)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

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

      when_ "the agent deletes legacy.md and the engineer re-syncs", context do
        :ok = Environments.delete_file(context.environment, @rule_path)

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

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
               "Expected legacy.md to be absent from search after delete + re-sync, got:\n#{body}"
        {:ok, context}
      end
    end
  end
end
