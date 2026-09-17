defmodule CodeMySpecTest.TurnEventRelay do
  @moduledoc """
  The one hop an in-process agent has always been missing: its turn events
  reaching the server.

  `CmsHarness.Agents.launch/1` defaults `on_event` to
  `ChannelClient.report_turn_event/3`, which looks the copy's channel up in
  `CmsHarness.Registry` and answers `:ok` when there is none. In a spex there
  never is one, so every agent the suite has ever started ran with its
  transcript going nowhere — the turn happened, the tool calls happened, and
  the server heard about none of it.

  That is invisible until something asks what an agent did. Story 1070's
  criteria are all of that shape: the agent is the user, the chat is the
  surface, and what it *called* is the assertion. With events dropped, the only
  way to ask is `Alloy`'s own in-memory history, which is the agent asked about
  itself — and an agent that reports a tool call it never actually made would
  answer that question the same way.

  So the relay pushes them over a real `harness_project` channel, with the same
  `agent_turn_event` payload `ChannelClient` puts on the wire. The hop that is
  stood in for is the socket, and only the socket, which is the bargain
  `CodeMySpecTest.InProcessAgentTransport` already strikes for everything else.

  ## Installed, not defaulted

  Off unless a scenario installs it, because the key is global: a concurrent
  spex would pick up whichever socket the other one registered, and the
  transcript would land on the wrong project. `install/1` is `async: false`
  territory for the same reason `CodeMySpecTest.RecordingAgentTransport.listen/0`
  is.
  """

  @key {__MODULE__, :socket}

  @doc """
  Send every agent's turn events over this socket until the test ends.

  The socket must be a joined `harness_project` channel — the same join the
  criterion made to bring the checkout onto the harness.
  """
  @spec install(Phoenix.Socket.t()) :: :ok
  def install(socket) do
    :persistent_term.put(@key, socket)
    ExUnit.Callbacks.on_exit(fn -> uninstall() end)
  end

  @doc "Stop relaying. Agents started afterwards report nowhere again."
  @spec uninstall() :: :ok
  def uninstall, do: :persistent_term.erase(@key) && :ok

  @doc """
  The `on_event` callback for a launch, or `nil` when nothing is listening.

  `nil` rather than a no-op function on purpose: `CmsHarness.Agents.launch/1`
  reads `request["on_event"] || reporter_for(...)`, so `nil` leaves the
  production default in place and a spex that installed nothing behaves exactly
  as it did before.
  """
  @spec reporter() :: (String.t(), map() -> :ok) | nil
  def reporter do
    case :persistent_term.get(@key, nil) do
      nil ->
        nil

      socket ->
        fn agent_id, envelope ->
          Phoenix.ChannelTest.push(socket, "agent_turn_event", %{
            "agent_id" => agent_id,
            "event" => CmsHarnessTest.Machine.encode_turn_event(envelope)
          })

          :ok
        end
    end
  end
end
