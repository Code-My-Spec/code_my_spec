defmodule CodeMySpecSpex.Story127.Criterion5934Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5934 — Single-path sync on a path that no longer exists on
  disk deletes the File row.

  The watcher's delete-event path runs `ProjectSync.Sync.sync_path/2`
  with an absolute path that has just vanished. The orchestrator stats
  the path through the environment, gets nil, and reaps the row. The
  user-visible proof: after deleting one file and pushing the
  single-path watcher event for it, the Files projection no longer
  lists that file — and crucially, untouched siblings remain.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @impl_a "lib/alpha.ex"
  @impl_b "lib/bravo.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees the projection reaped for a single deleted path" do
    scenario "watcher's single-path event on a missing path removes its File row" do
      given_ "the agent has written two impl files and the engineer has full-synced",
             context do
        :ok = Environments.write_file(context.environment, @impl_a, impl_a())
        :ok = Environments.write_file(context.environment, @impl_b, impl_b())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "both files appear in the projection", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert has_element?(files_live, "[data-file-path=\"#{@impl_a}\"]")
        assert has_element?(files_live, "[data-file-path=\"#{@impl_b}\"]")
        {:ok, context}
      end

      when_ "the agent deletes alpha and the watcher fires a single-path event for it",
            context do
        :ok = Environments.delete_file(context.environment, @impl_a)
        {:ok, _} = Fixtures.notify_file_changed(context.scope, @impl_a)
        {:ok, context}
      end

      then_ "alpha's row is reaped while bravo's row remains", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        refute has_element?(files_live, "[data-file-path=\"#{@impl_a}\"]")

        # Anchor: bravo's row proves sync_path scoped to alpha only.
        assert has_element?(files_live, "[data-file-path=\"#{@impl_b}\"]")
        {:ok, context}
      end
    end
  end

  defp impl_a do
    """
    defmodule Alpha do
      @moduledoc false
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
end
