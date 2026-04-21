defmodule CodeMySpecLocalWeb.Application do
  @moduledoc """
  CLI/local application.

  Boots with SQLite, local web endpoint, and MCP server.
  No main web endpoint, no Cloudflare tunnel.
  """
  use Application

  @impl true
  def start(_type, _args) do
    handle_cli_args(cli_argv())

    ensure_directories()

    children = [
      CodeMySpec.Vault,
      CodeMySpec.Repo,
      CodeMySpec.Environments.registry_child_spec(),
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

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        print_server_banner()
        {:ok, pid}

      other ->
        other
    end
  end

  defp cli_argv do
    mod = Burrito.Util.Args

    if Code.ensure_loaded?(mod) and function_exported?(mod, :argv, 0) do
      try do
        apply(mod, :argv, []) || []
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp handle_cli_args(argv) do
    cond do
      "--version" in argv or "-v" in argv ->
        IO.puts(version_string())
        System.halt(0)

      "--help" in argv or "-h" in argv ->
        IO.puts(help_text())
        System.halt(0)

      true ->
        case reject_known(argv) do
          [] ->
            :ok

          [first | _] ->
            IO.puts(:stderr, "cms: unknown option #{inspect(first)}\n")
            IO.puts(:stderr, help_text())
            System.halt(2)
        end
    end
  end

  defp reject_known(argv) do
    Enum.reject(argv, &(&1 in ["--help", "-h", "--version", "-v", "server", "--", ""]))
  end

  defp version_string do
    version = Application.spec(:code_my_spec, :vsn) |> to_string()
    "cms #{version}"
  end

  defp help_text do
    """
    cms — CodeMySpec local server

    This is a background server, not an interactive CLI. It boots the local
    Phoenix endpoint on :4003 and an MCP server that your Claude Code
    extension talks to. Run it and leave it running.

    Usage:
      cms              Start the server (ctrl-C to stop).
      cms --version    Print version and exit.
      cms --help       Print this help and exit.

    Your project workflow happens through the Claude Code extension —
    invoke the codemyspec MCP tools and slash commands there. The
    extension points at http://localhost:4003/mcp, which this process
    serves.
    """
  end

  defp print_server_banner do
    if not silent?() do
      IO.puts("cms #{Application.spec(:code_my_spec, :vsn)} — listening on http://localhost:4003 (ctrl-C to stop)")
    end
  end

  defp silent? do
    System.get_env("CMS_QUIET") in ["1", "true"]
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_directories do
    File.mkdir_p!(Path.expand("~/.codemyspec"))
  end
end
