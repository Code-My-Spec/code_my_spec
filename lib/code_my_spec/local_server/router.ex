defmodule CodeMySpec.LocalServer.Router do
  @moduledoc """
  Router for the local MCP server.

  Handles MCP requests from Claude Code via HTTP/SSE transport.
  """

  use Plug.Router
  require Logger

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # Health check - no auth required
  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  # MCP routes - require localhost, working dir, and scope
  forward "/mcp/architecture", to: CodeMySpec.LocalServer.McpPlug,
    init_opts: [server: CodeMySpec.McpServers.ArchitectureServer]

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end
end
