defmodule CodeMySpecLocalWeb.SyncController do
  @moduledoc """
  LLM API for triggering project sync.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.ProjectSync.Sync

  def create(conn, _params) do
    scope = conn.assigns.current_scope

    case Sync.incremental_sync(scope, write_status: true) do
      {:ok, result} ->
        components = length(Map.get(result, :all_components, []))
        changed = length(Map.get(result, :changed_ids, []))
        updated = Map.get(result, :requirements_updated, 0)

        text(conn, """
        # Sync Complete

        - Components: #{components}
        - Changed: #{changed}
        - Requirements updated: #{updated}
        """)

      {:error, reason} ->
        conn |> put_status(500) |> text("Sync failed: #{inspect(reason)}")
    end
  end
end
