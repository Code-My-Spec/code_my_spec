defmodule CodeMySpec.LocalServer.Config do
  @moduledoc """
  Configuration for the local MCP server.

  This server runs on localhost for Claude Code to connect to via HTTP/SSE,
  eliminating the BEAM cold start penalty of stdio transport.
  """

  @default_port 4002

  @doc """
  Get the local server port.
  """
  def port do
    Application.get_env(:code_my_spec, :local_server_port, @default_port)
  end

  @doc """
  Get the local server base URL.
  """
  def url do
    "http://localhost:#{port()}"
  end

  @doc """
  Get the MCP endpoint URL.
  """
  def mcp_url do
    "#{url()}/mcp/architecture"
  end
end
