defmodule CodeMySpec.LocalServer do
  @moduledoc """
  Local HTTP server for MCP connections from Claude Code.

  This server runs on localhost and provides MCP endpoints via HTTP/SSE,
  eliminating the 2-3 second BEAM cold start of stdio transport.

  ## Usage

  Start the server:

      CodeMySpec.LocalServer.start()

  Or add to supervision tree:

      {CodeMySpec.LocalServer, port: 4001}

  ## Architecture

  Claude Code connects via HTTP with `X-Working-Dir` header specifying
  which project directory it's working in. The server:

  1. Validates the connection is from localhost
  2. Extracts the working directory from the header
  3. Loads the project scope from `.code_my_spec/config.yml`
  4. Routes MCP requests to the ArchitectureServer
  """

  require Logger

  alias CodeMySpec.LocalServer.Config

  @doc """
  Child spec for supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Starts the server linked to the current process.
  """
  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, Config.port())

    Logger.info("[LocalServer] Starting on port #{port}")

    case Bandit.start_link(plug: CodeMySpec.LocalServer.Router, port: port) do
      {:ok, pid} ->
        Logger.info("[LocalServer] Started at #{Config.url()}")
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} ->
        Logger.warning("[LocalServer] Port #{port} already in use")
        {:error, :eaddrinuse}

      {:error, reason} ->
        Logger.error("[LocalServer] Failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Starts the server dynamically (not linked).
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, Config.port())

    case Bandit.start_link(plug: CodeMySpec.LocalServer.Router, port: port) do
      {:ok, pid} ->
        Process.unlink(pid)
        Logger.info("[LocalServer] Started at #{Config.url()}")
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} ->
        Logger.warning("[LocalServer] Port #{port} already in use")
        {:error, :eaddrinuse}

      {:error, reason} ->
        Logger.error("[LocalServer] Failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops a running server.
  """
  def stop(pid) when is_pid(pid) do
    Logger.info("[LocalServer] Stopping")
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  def stop(_), do: :ok
end
