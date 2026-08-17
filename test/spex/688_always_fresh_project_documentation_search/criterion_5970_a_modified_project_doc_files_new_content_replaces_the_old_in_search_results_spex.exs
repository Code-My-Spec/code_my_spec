defmodule CodeMySpecSpex.Story688.Criterion5970Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5970 — A modified project doc file's new content replaces
  the old in search results.

  Same rule as 5969 (the embedding store mirrors disk), exercised on
  the modify path: when content changes, search reflects the new
  content and the old content no longer surfaces.

  Driven via `Fixtures.notify_file_changed/2` — the production
  surface is the file watcher firing per-file `sync_path` events,
  which upsert the File row and run the embedding hook in one shot.

  See `criterion_5969_*_spex.exs` for the test-infrastructure
  assumptions about the configurable embedding serving.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @spec_path ".code_my_spec/spec/widget.spec.md"

  @v1_content """
  # Widget Context

  The Widget context exposes `create_widget/2` which inserts a new
  widget for the given scope.
  """

  @v2_content """
  # Widget Context

  The Widget context exposes `create_widget/3` which inserts a new
  widget for the given scope, account, and attrs map.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent sees updated content in semantic search after a doc file is edited" do
    scenario "a modified spec file's new content shows up in search and the old content does not" do
      given_ "widget.spec.md is embedded with the v1 (arity-2) content", context do
        :ok = Environments.write_file(context.environment, @spec_path, @v1_content)
        {:ok, _result} = Fixtures.notify_file_changed(context.scope, @spec_path)
        {:ok, context}
      end

      when_ "the agent rewrites the file as v2 (arity-3) and the watcher syncs it", context do
        :ok = Environments.write_file(context.environment, @spec_path, @v2_content)
        {:ok, _result} = Fixtures.notify_file_changed(context.scope, @spec_path)
        {:ok, context}
      end

      then_ "search for the v2 wording returns the updated content from widget.spec.md",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "create_widget arity 3 attrs", source: "spec", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "widget.spec.md",
               "Expected SemanticSearch to cite widget.spec.md, got:\n#{body}"

        assert body =~ "create_widget/3",
               "Expected v2 content to appear in results, got:\n#{body}"

        {:ok, context}
      end

      then_ "search for the v1 wording does not return the old content", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "create_widget arity 2 scope", source: "spec", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        # Anchor: a search header rendered, so this is a real "no match"
        # against widget.spec.md, not a swallowed error.
        assert body =~ "Search:"

        refute body =~ "inserts a new widget for the given scope.\n",
               "Expected v1's distinguishing wording to be gone after re-sync, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
