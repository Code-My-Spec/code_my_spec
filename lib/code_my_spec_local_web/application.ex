defmodule CodeMySpecLocalWeb.Application do
  @moduledoc """
  CLI/local application.

  Boots with SQLite, local web endpoint, and MCP server.
  No main web endpoint, no Cloudflare tunnel.
  """
  use Application

  @impl true
  def start(_type, _args) do
    ensure_directories()

    children = [
      CodeMySpec.Vault,
      CodeMySpec.Repo,
      CodeMySpecLocalWeb.Migrator,
      {Phoenix.PubSub, name: CodeMySpec.PubSub},
      CodeMySpec.Auth.AuthState,
      CodeMySpec.Embeddings.Serving,
      {CodeMySpec.McpServers.LocalServer, transport: {:streamable_http, start: true}},
      CodeMySpecLocalWeb.Endpoint,
      CodeMySpec.ProjectSync.FileWatcherServer,
      CodeMySpec.Stories.BootSync,
      CodeMySpecLocalWeb.SocketSupervisor
    ]

    opts = [strategy: :one_for_one, name: CodeMySpec.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_directories do
    File.mkdir_p!(Path.expand("~/.codemyspec"))
  end
end
