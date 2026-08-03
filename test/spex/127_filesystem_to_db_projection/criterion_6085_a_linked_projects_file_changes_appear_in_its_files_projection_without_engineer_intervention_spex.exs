defmodule CodeMySpecSpex.Story127.Criterion6085Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 6085 — A linked project's file changes appear in its /files
  projection without engineer intervention.

  Covers the rule "The watcher attaches automatically to every linked
  project on boot, and to newly-linked projects when they appear. The
  agent never has to ask for sync to start."

  The user-observable: the engineer does NOT click the sync button.
  A file change (via the watcher's `Sync.sync_path/2` event) flows
  straight into the Files projection. The boot-scan / supervisor
  mechanics live in `file_watcher_server_test.exs` as unit tests; this
  spec proves the contract the rule promises from the engineer's
  perspective.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @impl_path "lib/auto_synced_module.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees file changes appear without triggering a manual sync" do
    scenario "agent writes a file in a watched subtree; projection updates with no click" do
      given_ "the engineer has a linked project with no files synced yet", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        refute has_element?(files_live, "[data-file-path=\"#{@impl_path}\"]")
        {:ok, context}
      end

      when_ "the agent writes a file and the watcher fires its sync event",
            context do
        :ok = Environments.write_file(context.environment, @impl_path, impl_content())
        {:ok, _} = Fixtures.notify_file_changed(context.scope, @impl_path)
        {:ok, context}
      end

      then_ "the new file appears in the projection without any engineer action",
            context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert has_element?(files_live, "[data-file-path=\"#{@impl_path}\"]")
        {:ok, context}
      end
    end
  end

  defp impl_content do
    """
    defmodule AutoSyncedModule do
      @moduledoc false
    end
    """
  end
end
