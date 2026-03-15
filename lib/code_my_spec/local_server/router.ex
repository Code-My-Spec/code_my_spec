defmodule CodeMySpec.LocalServer.Router do
  @moduledoc """
  Router for the local MCP server.

  Handles MCP requests from Claude Code via HTTP/SSE transport.
  """

  use Plug.Router
  require Logger

  alias CodeMySpec.LocalServer.Controllers.{
    AgentTaskController,
    BootstrapController,
    HookController,
    IssuesController,
    NotificationController,
    PermissionController,
    StoryComponentController,
    StoryLinkageController
  }
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

  # --- Bootstrap routes (LocalOnly only, no LocalScope) ---

  # Check auth status
  get "/api/bootstrap/auth/status" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&BootstrapController.auth_status/1)
  end

  # Start OAuth PKCE flow
  post "/api/bootstrap/auth/start" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&BootstrapController.auth_start/1)
  end

  # OAuth callback (browser redirects here)
  get "/api/bootstrap/auth/callback" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&BootstrapController.auth_callback/1)
  end

  # List projects from server
  get "/api/bootstrap/projects" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&BootstrapController.list_projects/1)
  end

  # Init project config
  post "/api/bootstrap/init" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&BootstrapController.init_project/1)
  end

  # Install app symlinks (framework knowledge + tools)
  post "/api/bootstrap/install-symlinks" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&BootstrapController.install_symlinks/1)
  end

  # Generate .code_my_spec/AGENTS.md
  post "/api/bootstrap/install-agents-md" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&BootstrapController.install_agents_md/1)
  end

  # Install/update CLAUDE.md managed section
  post "/api/bootstrap/install-claude-md" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&BootstrapController.install_claude_md/1)
  end

  # Install default rules
  post "/api/bootstrap/install-rules" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&BootstrapController.install_rules/1)
  end

  # Project setup (no config.yml needed — this is what creates it)
  post "/api/bootstrap/setup" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&BootstrapController.setup_project/1)
  end

  # --- Existing routes ---

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

  # Send a push notification with arbitrary text
  post "/api/notifications/send" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&NotificationController.send_notification/1)
  end

  # Create a permission request (from hook script)
  post "/api/permissions/request" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&PermissionController.create/1)
  end

  # SSE stream — hook script waits here for approval/denial
  get "/api/permissions/:id/stream" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&PermissionController.stream/1)
  end

  # Respond to a permission request (from Web UI / push notification action)
  post "/api/permissions/:id/respond" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&PermissionController.respond/1)
  end

  # Link a story to a component by module name
  post "/api/stories/set-component" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&StoryComponentController.set/1)
  end

  # Analyze story-component linkage
  get "/api/stories/linkage" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&StoryLinkageController.analyze/1)
  end

  # Issues API - require localhost, working dir, and scope
  get "/api/issues" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&IssuesController.index/1)
  end

  get "/api/issues/:id" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&IssuesController.show/1)
  end

  post "/api/issues" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&IssuesController.create/1)
  end

  post "/api/issues/:id/accept" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&IssuesController.accept/1)
  end

  post "/api/issues/:id/dismiss" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&IssuesController.dismiss/1)
  end

  post "/api/issues/:id/resolve" do
    conn
    |> Plugs.LocalOnly.call([])
    |> maybe_continue(&Plugs.WorkingDir.call(&1, []))
    |> maybe_continue(&Plugs.LocalScope.call(&1, []))
    |> maybe_continue(&IssuesController.resolve/1)
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
