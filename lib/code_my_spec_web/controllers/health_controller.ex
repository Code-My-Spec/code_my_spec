defmodule CodeMySpecWeb.HealthController do
  @moduledoc """
  `GET /health`: 200 when the database answers and no migration is pending,
  503 otherwise. `just reload` reads it after a promote's reload, so a reload
  that compiled but did not migrate falls back to a restart.

  In dev, `Phoenix.Ecto.CheckRepoStatus` answers a pending migration with a
  500 before this runs; either way the status is not 200.
  """
  use CodeMySpecWeb, :controller

  alias CodeMySpec.AppHealth

  def index(conn, _params) do
    health = AppHealth.check()

    conn
    |> put_status(if health.healthy, do: 200, else: 503)
    |> json(%{
      status: if(health.healthy, do: "ok", else: "unhealthy"),
      database: database(health.database),
      pending_migrations: health.pending_migrations,
      harness_connected: health.harness_connected
    })
  end

  defp database(:ok), do: "ok"
  defp database({:error, message}), do: message
end
