defmodule CodeMySpec.LocalServer.McpPlug do
  @moduledoc """
  Plug that wraps Hermes MCP transport with local security and context plugs.
  """

  @behaviour Plug

  alias CodeMySpec.LocalServer.Plugs

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    hermes_opts = Hermes.Server.Transport.StreamableHTTP.Plug.init(server: server)
    %{hermes_opts: hermes_opts}
  end

  @impl true
  def call(conn, %{hermes_opts: hermes_opts}) do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&Hermes.Server.Transport.StreamableHTTP.Plug.call(&1, hermes_opts))
  end

  defp maybe_continue(%Plug.Conn{halted: true} = conn, _fun), do: conn
  defp maybe_continue(conn, fun), do: fun.(conn)
end
