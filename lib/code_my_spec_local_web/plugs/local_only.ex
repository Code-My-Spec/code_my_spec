defmodule CodeMySpecLocalWeb.Plugs.LocalOnly do
  @moduledoc """
  Restricts access to localhost connections only.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.remote_ip do
      {127, 0, 0, 1} -> conn
      {0, 0, 0, 0, 0, 0, 0, 1} -> conn
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "Localhost only"}))
        |> halt()
    end
  end
end
