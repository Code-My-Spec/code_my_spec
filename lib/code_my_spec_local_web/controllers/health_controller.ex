defmodule CodeMySpecLocalWeb.HealthController do
  use CodeMySpecLocalWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
