defmodule CodeMySpecCli.McpRelay do
  @moduledoc """
  Thin stdio ↔ running-server MCP relay.

  `cms mcp` runs this: Claude Code spawns it and speaks MCP JSON-RPC over
  stdin/stdout (so Node never touches HTTP — no cert/localhost-HTTP griping).
  The relay forwards each message to the one running `cms server` over its
  Anubis streamable-HTTP MCP endpoint and pumps responses back to stdout.

  It holds no database and no application state — the running server is the
  single source of truth (one SQLite client, live PubSub intact). The
  relay↔server hop is localhost Elixir↔Elixir HTTP, invisible to Node.

  Anubis's streamable-HTTP *client* transport does the real work (SSE,
  session id, reconnect); this module is just the stdin/stdout pump. Received
  server messages arrive as `cast(client, {:response, msg})`; we write them to
  stdout. Requests read off stdin go out via `send_message/3`.
  """
  use GenServer
  require Logger

  alias Anubis.Transport.StreamableHTTP

  @default_base_url "http://localhost:4004"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # Logs MUST go to stderr — stdout is the MCP JSON-RPC channel and a single
    # stray log line corrupts the protocol. Merge type: :standard_error into the
    # default handler's existing config (a bare replace can be ignored/rejected
    # depending on the handler, which is how debug logs leaked to stdout).
    redirect_logs_to_stderr()

    base_url = Keyword.get(opts, :base_url, @default_base_url)

    case StreamableHTTP.start_link(
           client: self(),
           base_url: base_url,
           mcp_path: "/mcp",
           # The shared server resolves scope from the working directory (it
           # serves every local project). Over HTTP this rode in the
           # X-Working-Dir header; the relay carries it the same way, from the
           # dir Claude Code spawned us in.
           headers: %{"X-Working-Dir" => working_dir()},
           # enable_sse: also open the server→client SSE channel so we relay
           # server-initiated notifications/requests, not just responses.
           enable_sse: true
         ) do
      {:ok, transport} ->
        parent = self()
        _reader = spawn_link(fn -> read_loop(parent) end)
        {:ok, %{transport: transport, base_url: base_url}}

      {:error, reason} ->
        Logger.error("[McpRelay] could not connect to #{base_url}: #{inspect(reason)}")
        {:stop, {:transport_start_failed, reason}}
    end
  end

  # --- stdin (from Claude) → server ---------------------------------------

  @impl true
  def handle_info({:mcp_line, line}, state) do
    case StreamableHTTP.send_message(state.transport, line, timeout: to_timeout(minute: 5)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("[McpRelay] send failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:stdin_closed, _state) do
    # Claude closed the pipe — the session is over. Terminate the whole `cms mcp`
    # OS process; stopping just this GenServer would leave the VM lingering
    # (the supervisor/release keeps it alive), orphaning a process per session.
    System.halt(0)
  end

  # --- server → stdout (to Claude) ----------------------------------------

  @impl true
  def handle_cast({:response, message}, state) when is_binary(message) do
    IO.write([message, ?\n])
    {:noreply, state}
  end

  # Transport lifecycle notifications — nothing to relay; the plugin drives its
  # own initialize handshake, which we pass through transparently.
  def handle_cast(:initialize, state), do: {:noreply, state}

  def handle_cast(:session_expired, _state) do
    # Server dropped our session — we can't serve anymore. Exit the process so
    # Claude Code notices and respawns a fresh `cms mcp` (don't linger).
    Logger.error("[McpRelay] server session expired")
    System.halt(1)
  end

  def handle_cast(_other, state), do: {:noreply, state}

  # Claude Code spawns the relay in the project directory and also exports
  # CLAUDE_PROJECT_DIR; prefer the explicit env, fall back to cwd.
  defp working_dir do
    System.get_env("CLAUDE_PROJECT_DIR") || File.cwd!()
  end

  # Guarantee stdout carries ONLY MCP JSON by REPLACING the default logger
  # handler with one that writes to stderr. `update_handler_config(:config, ...)`
  # proved unreliable across envs (error logs still reached stdout), and in
  # prod_cli the relay skips the file logger, so the live default handler would
  # otherwise dump straight onto the MCP channel. Also drop the primary level to
  # :info so the transport's debug chatter never fires.
  defp redirect_logs_to_stderr do
    formatter =
      case :logger.get_handler_config(:default) do
        {:ok, %{formatter: f}} -> f
        _ -> {:logger_formatter, %{legacy_header: false, single_line: true}}
      end

    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error},
      formatter: formatter
    })

    :logger.update_primary_config(%{level: :info})
  rescue
    _ -> :ok
  end

  # --- stdin reader -------------------------------------------------------

  # Blocking line reader in a linked process; each MCP message is one line of
  # JSON on stdio. Forwards lines to the relay GenServer and signals EOF.
  defp read_loop(parent) do
    case IO.read(:stdio, :line) do
      :eof ->
        send(parent, :stdin_closed)

      {:error, reason} ->
        send(parent, {:mcp_line, reason})
        send(parent, :stdin_closed)

      data when is_binary(data) ->
        case String.trim_trailing(data) do
          "" -> :ok
          line -> send(parent, {:mcp_line, line})
        end

        read_loop(parent)
    end
  end
end
