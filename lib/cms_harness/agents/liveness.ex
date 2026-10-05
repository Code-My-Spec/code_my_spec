defmodule CmsHarness.Agents.Liveness do
  @moduledoc """
  Which agents are alive on this harness, by working copy, as ups and downs.

  Every agent process the engine starts is watched here and monitored, so its
  death — a crash, a stop, a kill — is a `:DOWN` the moment it happens. Each
  project's `ChannelClient` subscribes and turns the stream into Phoenix
  Presence on the server (`.code_my_spec/plans/agent-liveness-from-presence.md`).

  A crash its `Engine.Keeper` restarts is a down and then an up. The Keeper is
  watched too: when it gives up on a crash loop, the agent is gone for good,
  and that is said once, as `:gave_up` with the last crash's reason — the only
  death the server acts on. A Keeper that ends because its agent was stopped
  says nothing more than the stop's own down.

  Subscribers are sent `{:agent_liveness, :up | :down | :gave_up, agent_id,
  root, reason}`, `root` being the working copy the agent runs in.

  Not running (the harness tree is not started — a test, a CLI command): every
  call answers as if nothing were alive, because nothing it watched is.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Watch `pid` as `agent_id`'s process, running in the working copy at `root`."
  @spec watch(String.t(), pid(), String.t()) :: :ok
  def watch(agent_id, pid, root), do: cast({:watch, agent_id, pid, Path.expand(root)})

  @doc "Watch `keeper` as `agent_id`'s `Engine.Keeper`, for it giving up."
  @spec watch_keeper(String.t(), pid(), String.t()) :: :ok
  def watch_keeper(agent_id, keeper, root),
    do: cast({:watch_keeper, agent_id, keeper, Path.expand(root)})

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
  #
  # `keepers` by monitor ref; `exits` holds each agent's last process exit
  # reason, and `orphaned` the agents whose Keeper's `:DOWN` arrived before
  # their last process's — two monitors, two senders, no promised order.
  def init(:ok),
    do: {:ok, %{agents: %{}, keepers: %{}, exits: %{}, orphaned: %{}, subscribers: %{}}}

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

  def handle_cast({:watch_keeper, agent_id, keeper, root}, state) do
    if Enum.any?(state.keepers, fn {_ref, watched} -> watched.pid == keeper end) do
      {:noreply, state}
    else
      ref = Process.monitor(keeper)
      {:noreply, put_in(state.keepers[ref], %{id: agent_id, pid: keeper, root: root})}
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
    cond do
      Map.has_key?(state.agents, ref) -> {:noreply, process_down(state, ref, reason)}
      Map.has_key?(state.keepers, ref) -> {:noreply, keeper_down(state, ref)}
      true -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
    end
  end

  defp process_down(state, ref, reason) do
    {%{id: id, root: root}, agents} = Map.pop(state.agents, ref)
    notify(state, :down, id, root, reason)
    state = %{state | agents: agents, exits: Map.put(state.exits, id, reason)}

    if Map.has_key?(state.orphaned, id), do: ended(state, id, root), else: state
  end

  # The Keeper went: with its process already down, decide now; with it still
  # watched, its `:DOWN` is on the way and decides.
  defp keeper_down(state, ref) do
    {%{id: id, root: root}, keepers} = Map.pop(state.keepers, ref)
    state = %{state | keepers: keepers}

    if Enum.any?(state.agents, fn {_ref, agent} -> agent.id == id end),
      do: %{state | orphaned: Map.put(state.orphaned, id, root)},
      else: ended(state, id, root)
  end

  defp ended(state, id, root) do
    {reason, exits} = Map.pop(state.exits, id)
    if crashed?(reason), do: notify(state, :gave_up, id, root, reason)
    %{state | exits: exits, orphaned: Map.delete(state.orphaned, id)}
  end

  defp crashed?(reason) when reason in [nil, :normal, :shutdown], do: false
  defp crashed?({:shutdown, _}), do: false
  defp crashed?(_reason), do: true

  defp notify(state, kind, agent_id, root, reason) do
    for {subscriber, _ref} <- state.subscribers,
        do: send(subscriber, {:agent_liveness, kind, agent_id, root, reason})

    :ok
  end
end
