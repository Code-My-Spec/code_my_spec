defmodule CodeMySpecSpex.Story127.Criterion5922Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5922 — Single-path sync touches exactly one file.

  Covers the contract that the file watcher's per-event handler invokes
  `ProjectSync.Sync.sync_path/2`, which refreshes only the path it was
  given. The user-visible proof: after editing one file and pushing one
  synthetic watcher event, the Files page shows the new fingerprint on
  that file and the unchanged fingerprint on its sibling.

  The watcher's OS-level subscription doesn't see memfs writes, so the
  spec drives the same orchestrator the watcher would (`Sync.sync_path/2`),
  bypassing the OS event source. This is the explicit reason we split
  the watcher's two responsibilities — `Sync` is the public surface,
  the FileSystem subscription is just one of its callers.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @impl_a "lib/alpha.ex"
  @impl_b "lib/bravo.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees a single-path watcher event refresh exactly one file" do
    scenario "editing alpha and notifying the watcher leaves bravo's projection untouched" do
      given_ "the agent has written two impl files and the engineer has full-synced",
             context do
        :ok = Environments.write_file(context.environment, @impl_a, impl_a_v1())
        :ok = Environments.write_file(context.environment, @impl_b, impl_b())

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "both files appear in the projection with their v1 fingerprints",
             context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_a}\"] [data-fingerprint=\"#{sha256(impl_a_v1())}\"]"
               )

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_b}\"] [data-fingerprint=\"#{sha256(impl_b())}\"]"
               )

        {:ok, context}
      end

      when_ "the agent edits alpha and pushes a single-path watcher event", context do
        :ok = Environments.write_file(context.environment, @impl_a, impl_a_v2())
        {:ok, _} = Fixtures.notify_file_changed(context.scope, @impl_a)
        {:ok, context}
      end

      then_ "alpha shows the v2 fingerprint while bravo's projection stays on v1",
            context do
        # The LiveView received the {:watcher_synced, ...} broadcast and
        # refreshed its result assign; assert via a fresh mount to keep
        # the assertion independent of in-process state.
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_a}\"] [data-fingerprint=\"#{sha256(impl_a_v2())}\"]"
               )

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_b}\"] [data-fingerprint=\"#{sha256(impl_b())}\"]"
               )

        refute has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_a}\"] [data-fingerprint=\"#{sha256(impl_a_v1())}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp impl_a_v1 do
    """
    defmodule Alpha do
      @moduledoc "v1"
    end
    """
  end

  defp impl_a_v2 do
    """
    defmodule Alpha do
      @moduledoc "v2"
    end
    """
  end

  defp impl_b do
    """
    defmodule Bravo do
      @moduledoc false
    end
    """
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
