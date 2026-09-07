defmodule CodeMySpecLocalWeb.McpPlug do
  @moduledoc """
  Forwards MCP requests to the Anubis StreamableHTTP transport.
  """

  alias Anubis.Server.Transport.StreamableHTTP

  @behaviour Plug

  @impl true
  def init(opts) do
    StreamableHTTP.Plug.init(opts)
  end

  @impl true
  def call(conn, opts) do
    require Logger
    Logger.debug("[McpPlug] headers: #{inspect(conn.req_headers)}")
    Logger.debug("[McpPlug] assigns: #{inspect(Map.keys(conn.assigns))}")
    StreamableHTTP.Plug.call(conn, opts)
  end
end
