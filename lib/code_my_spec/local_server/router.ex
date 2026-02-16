defmodule CodeMySpec.LocalServer.Router do
  @moduledoc """
  Router for the local MCP server.

  Handles MCP requests from Claude Code via HTTP/SSE transport.
  """

  use Plug.Router
  require Logger

  alias CodeMySpec.LocalServer.Controllers.{AgentTaskController, HookController}
  alias CodeMySpec.LocalServer.Plugs

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # Health check - no auth required
  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  # Agent task API - require localhost, working dir, and scope
  post "/api/agent-tasks/start" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&AgentTaskController.start/1)
  end

  # Hook API - require localhost, working dir, and scope
  post "/api/hooks" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&HookController.handle/1)
  end

  # MCP routes - require localhost, working dir, and scope
  forward "/mcp/architecture",
    to: CodeMySpec.LocalServer.McpPlug,
    init_opts: [server: CodeMySpec.McpServers.ArchitectureServer]

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  defp maybe_continue(%Plug.Conn{halted: true} = conn, _fun), do: conn
  defp maybe_continue(conn, fun), do: fun.(conn)
end
