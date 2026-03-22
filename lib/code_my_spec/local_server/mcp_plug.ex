defmodule CodeMySpec.LocalServer.McpPlug do
  @moduledoc """
  Plug that wraps Anubis MCP transport with local security and context plugs.
  """

  @behaviour Plug

  alias CodeMySpec.LocalServer.Plugs

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    %{server: server}
  end

  @impl true
  def call(conn, %{server: server}) do
    anubis_opts = Anubis.Server.Transport.StreamableHTTP.Plug.init(server: server)

    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&Anubis.Server.Transport.StreamableHTTP.Plug.call(&1, anubis_opts))
  end

  defp maybe_continue(%Plug.Conn{halted: true} = conn, _fun), do: conn
  defp maybe_continue(conn, fun), do: fun.(conn)
end
