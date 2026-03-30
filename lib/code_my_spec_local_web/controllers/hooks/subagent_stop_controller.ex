defmodule CodeMySpecLocalWeb.Hooks.SubagentStopController do
  @moduledoc """
  Handles the SubagentStop hook event.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync

  def handle(conn, _params) do
    scope = conn.assigns.current_scope

    # Sync files so the parent agent sees updated state
    if scope.cwd do
      FileSync.sync(scope, base_dir: scope.cwd)
      FileComponentSync.sync_from_files(scope, base_dir: scope.cwd)
    end

    json(conn, %{})
  end
end
