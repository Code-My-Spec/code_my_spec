defmodule CmsHarness.Mcp.Session do
  @moduledoc """
  One agent's MCP session, as a supervised process (phase 2b).

  It sits in the agent's `Engine.Keeper` ahead of the engine, so the engine is
  started after it and goes down with it. An engine never holds a dead
  client: if the session dies, the engine is restarted with a fresh one, and
  both restarts count against the Keeper's bound. A session that cannot
  connect is a crash loop that gives up. It used to leave a running agent with
  no tools, and nothing said so.

  Connected in `init/1`, so the engine starts only once the session has
  answered. The client is kept in the registry under `{:mcp_session,
  agent_id}`, where the engine reads it (`client/1`). Closed in `terminate/2`,
  because the transport unlinks its client and nothing else would take it down.
  """

  use GenServer

  alias CmsHarness.Mcp
  alias CmsHarness.Mcp.Transport

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The agent's session client, or nil when it has none (an engine started bare)."
  @spec client(String.t()) :: term() | nil
  # Checked alive: the registry drops an exited owner's entry asynchronously,
  # so a lookup straight after a session dies still finds it (adb0a8530).
  def client(agent_id) do
    case Registry.lookup(CmsHarness.Registry, {:mcp_session, agent_id}) do
      [{pid, client}] -> if Process.alive?(pid), do: client
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    agent_id = Keyword.fetch!(opts, :agent_id)

    case Mcp.connect(
           agent_id,
           Keyword.get(opts, :working_copy_id),
           Keyword.get(opts, :working_copy)
         ) do
      {:ok, client} ->
        {:ok, _} = Registry.register(CmsHarness.Registry, {:mcp_session, agent_id}, client)
        {:ok, %{client: client, ref: watch(client)}}

      {:error, reason} ->
        {:stop, {:mcp_session, reason}}
    end
  end

  # The client is a process the transport started and unlinked, so its death
  # reaches this as a monitor rather than a link. A client that is not a
  # process (the in-VM test transport) has nothing to watch.
  defp watch({:via, _registry, _key} = client), do: client |> GenServer.whereis() |> monitor()
  defp watch(_client), do: nil

  defp monitor(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor(_nothing), do: nil

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state),
    do: {:stop, {:mcp_session_down, reason}, %{state | ref: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Transport.impl().disconnect(state.client)
    :ok
  end
end
