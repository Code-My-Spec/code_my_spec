defmodule CodeMySpec.LocalServer.Plugs.LocalOnly do
  @moduledoc """
  Security plug that rejects non-localhost connections.

  For local MCP endpoints, we only accept connections from localhost
  since the server has full file system access for the working directory.
  """

  import Plug.Conn

  @behaviour Plug

  @localhost_addrs [
    {127, 0, 0, 1},
    {0, 0, 0, 0, 0, 0, 0, 1}
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if localhost?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "Local connections only"}))
      |> halt()
    end
  end

  defp localhost?(conn) do
    conn.remote_ip in @localhost_addrs
  end
end
