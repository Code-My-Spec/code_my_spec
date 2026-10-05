defmodule CmsHarness.Agents.Liveness do
  @moduledoc """
  Which agents are alive on this harness, by working copy, as ups and downs.

  Every agent the engine starts is watched here and monitored, so its death —
  a crash, a stop, a kill — is a `:DOWN` the moment it happens rather than an
  absence the next 60-second report notices (agents are `restart: :temporary`
  and a death sends nothing on its own). Each project's `ChannelClient`
  subscribes and turns the stream into Phoenix Presence on the server
  (`.code_my_spec/plans/agent-liveness-from-presence.md`).

  Subscribers are sent `{:agent_liveness, :up | :down, agent_id, root, reason}`,
  `root` being the working copy the agent runs in.

  Not running (the harness tree is not started — a test, a CLI command): every
  call answers as if nothing were alive, because nothing it watched is.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Watch `pid` as `agent_id`'s process, running in the working copy at `root`."
  @spec watch(String.t(), pid(), String.t()) :: :ok
  def watch(agent_id, pid, root), do: cast({:watch, agent_id, pid, Path.expand(root)})

  @doc "Be sent every up and down from now on."
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()), do: cast({:subscribe, pid})

  @doc "The agents alive in the working copy at `root`."
  @spec present(String.t()) :: [String.t()]
  def present(root) do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      server -> GenServer.call(server, {:present, Path.expand(root)})
    end
  end

  defp cast(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      server -> GenServer.cast(server, message)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{agents: %{}, subscribers: %{}}}

  # A start that found the agent already running watches the same pid again;
  # one monitor and one `:up` are enough.
  @impl true
  def handle_cast({:watch, agent_id, pid, root}, state) do
    if Enum.any?(state.agents, fn {_ref, agent} -> agent.pid == pid end) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      notify(state, :up, agent_id, root, nil)
      {:noreply, put_in(state.agents[ref], %{id: agent_id, pid: pid, root: root})}
    end
  end

  def handle_cast({:subscribe, pid}, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:noreply, state}
    else
      {:noreply, put_in(state.subscribers[pid], Process.monitor(pid))}
    end
  end

  @impl true
  def handle_call({:present, root}, _from, state) do
    ids = for {_ref, %{root: ^root, id: id}} <- state.agents, do: id
    {:reply, ids, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.agents, ref) do
      {%{id: id, root: root}, agents} ->
        notify(state, :down, id, root, reason)
        {:noreply, %{state | agents: agents}}

      {nil, _agents} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
    end
  end

  defp notify(state, kind, agent_id, root, reason) do
    for {subscriber, _ref} <- state.subscribers,
        do: send(subscriber, {:agent_liveness, kind, agent_id, root, reason})

    :ok
  end
end
