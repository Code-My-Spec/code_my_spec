defmodule CodeMySpecTest.PresenceRelay do
  @moduledoc """
  The copy's channel's half of agent presence, for an agent started without one.

  `InProcessAgentTransport` removes the channel and only the channel. The
  channel is also what turns the harness's ups and downs (`Agents.Liveness`)
  into presence on the server, and a real agent the server cannot see as
  running is never delivered anything. So this does what the channel does, for
  one agent: tracked while its process is up, untracked when it goes down,
  tracked again when its Keeper restarts it — and each time it comes up, the
  same bell the channel rings (`Agents.came_up/2`).
  """

  use GenServer

  alias CmsHarness.Agents.Liveness
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL.Sandbox

  @doc "Mirror `agent`'s liveness into presence from now on. Idempotent."
  @spec relay(map()) :: :ok
  def relay(%{id: id} = agent) do
    case GenServer.start(__MODULE__, {agent, self()}, name: via(id)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def init({agent, caller}) do
    # The bell reads and writes the database, from here, on the caller's
    # behalf. A caller in shared mode owns nothing to allow, and needs nothing.
    # Without the sandbox (the evals run on a real pool) there is nothing to allow.
    if sandboxed?(), do: Sandbox.allow(CodeMySpec.Repo, caller, self())
    :ok = Liveness.subscribe()

    state = %{
      id: agent.id,
      topic: Presence.topic(agent.project_id),
      # The scope the server speaks to an agent in when nobody handed it one.
      scope: %Scope{
        active_account_id: agent.account_id,
        active_project_id: agent.project_id,
        active_working_copy_id: agent.working_copy_id
      },
      tracked?: false
    }

    # Its first up may have gone out before this subscribed.
    {:ok,
     if(match?({:ok, _}, CmsHarness.Agents.whereis(agent.id)), do: track(state), else: state)}
  end

  @impl true
  def handle_info({:agent_liveness, :up, id, _root, _reason}, %{id: id} = state),
    do: {:noreply, track(state)}

  def handle_info({:agent_liveness, kind, id, _root, _reason}, %{id: id} = state)
      when kind in [:down, :gave_up],
      do: {:noreply, untrack(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp track(%{tracked?: true} = state), do: state

  defp track(state) do
    {:ok, _ref} = Presence.track(self(), state.topic, state.id, %{})
    :ok = Agents.came_up(state.scope, state.id)
    %{state | tracked?: true}
  end

  defp untrack(%{tracked?: false} = state), do: state

  defp untrack(state) do
    :ok = Presence.untrack(self(), state.topic, state.id)
    %{state | tracked?: false}
  end

  defp via(id), do: {:via, Registry, {CmsHarness.Registry, {:presence_relay, id}}}

  defp sandboxed?,
    do: Application.get_env(:code_my_spec, CodeMySpec.Repo)[:pool] == Sandbox
end
