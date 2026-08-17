defmodule CodeMySpecSpex.Story688.Criterion5975Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5975 — Bundled framework knowledge is re-embedded after a
  CodeMySpec upgrade.

  Covers Rule "Project documentation embeddings reflect the file sync
  pipeline's view of disk." Bundled framework knowledge ships in the
  app's `priv/knowledge/` directory and changes only when CodeMySpec
  itself upgrades. The sync pipeline reads it directly — there is no
  working-tree copy — and re-embeds whichever files differ from
  what's currently in the embedding store.

  ## Observation surface

  The user-visible signal is `semantic_search` against the
  `"knowledge"` source. When the bundled file's content changes, the
  search returns the new content for that path; the old content no
  longer surfaces.

  ## Simulating an upgrade

  Production reads `Application.app_dir(:code_my_spec, "priv/knowledge")`.
  In test we point `:framework_knowledge_dir` at a temp directory we
  control, write v1 content, simulate the boot embed pass, then
  overwrite with v2 and simulate the boot pass again. Same code path;
  the only things the test swaps are which directory plays the role
  of "the binary's priv/knowledge" and a Fixtures helper standing in
  for the watcher's boot embed pass.

  The /files page's sync button no longer drives framework knowledge
  re-embedding — that's `FileWatcherServer.run_boot_embed_pass/1`, the
  always-fresh surface that fires when the cms binary itself restarts.
  `Fixtures.simulate_framework_knowledge_boot_embed/1` is the spex
  bridge to that surface.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @bundled_filename "liveview.md"

  @v1_content """
  # LiveView (v1)

  Use `Phoenix.Component.assign/2` to set assigns on the socket.
  This was the standard pattern through the v1 release line.
  """

  @v2_content """
  # LiveView (v2)

  Use `Phoenix.Component.assign/2` for single assigns and
  `Phoenix.Component.assign_async/3` for async-loaded data — the
  v2 release standardizes on async assigns where I/O is expected.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_framework_knowledge_dir

  spex "Agent sees updated framework knowledge after a CodeMySpec upgrade" do
    scenario "bundled knowledge file content changes after upgrade and sync" do
      given_ "the framework's bundled knowledge corpus has been embedded for v1", context do
        Fixtures.write_framework_knowledge_file(
          context.framework_knowledge_dir,
          @bundled_filename,
          @v1_content
        )

        :ok = Fixtures.simulate_framework_knowledge_boot_embed(context.scope)
        {:ok, context}
      end

      when_ "the user upgrades, the bundled file ships v2 content, and the watcher's boot pass runs",
            context do
        Fixtures.write_framework_knowledge_file(
          context.framework_knowledge_dir,
          @bundled_filename,
          @v2_content
        )

        :ok = Fixtures.simulate_framework_knowledge_boot_embed(context.scope)
        {:ok, context}
      end

      then_ "semantic_search over `knowledge` returns the v2 content for liveview.md",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "assign_async async-loaded data", source: "knowledge", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        assert body =~ "liveview.md",
               "Expected SemanticSearch to cite liveview.md, got:\n#{body}"

        assert body =~ "assign_async",
               "Expected v2 content to surface, got:\n#{body}"

        {:ok, context}
      end

      then_ "the v1-only wording no longer appears in search", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SemanticSearch.execute(
            %{query: "v1 release line standard pattern", source: "knowledge", limit: 5},
            frame
          )

        body = TaskResponseHelpers.response_text(response)

        # Anchor: the search header is present, so a v1 absence is a
        # real "no longer there," not a swallowed error.
        assert body =~ "Search:"

        refute body =~ "standard pattern through the v1 release line",
               "Expected v1's distinctive wording to be gone after upgrade + re-sync, got:\n#{body}"

        {:ok, context}
      end
    end
  end

  defp stub_framework_knowledge_dir(context) do
    {:ok, dir} = Briefly.create(directory: true)
    prior = Application.get_env(:code_my_spec, :framework_knowledge_dir)
    Application.put_env(:code_my_spec, :framework_knowledge_dir, dir)

    ExUnit.Callbacks.on_exit(fn -> restore_framework_knowledge_dir(prior) end)

    Map.put(context, :framework_knowledge_dir, dir)
  end

  defp restore_framework_knowledge_dir(nil),
    do: Application.delete_env(:code_my_spec, :framework_knowledge_dir)

  defp restore_framework_knowledge_dir(prior),
    do: Application.put_env(:code_my_spec, :framework_knowledge_dir, prior)
end
