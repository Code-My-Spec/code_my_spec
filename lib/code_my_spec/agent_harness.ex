defmodule CodeMySpec.AgentHarness do
  @moduledoc """
  Data-plane glue for the headless multi-agent harness (Story 704 / Pi orchestrator).

  The Pi harness — a manager plus `product` / `spec_writer` / `coding` / `qa`
  lanes — connects to the **local** app over `/harness_socket`; cms is the brain
  behind it. Two planes, deliberately split so the harness can run offsite as a
  paid service while the human talks to cms in a browser:

    * **Data plane (local app)** — `HarnessSocket` + `HarnessChannel` +
      `WorkSource`. Receives each agent's transcript (`agent_message`), lane
      parking (`lane_idle`), and the manager's `dispatch`; pushes work and human
      chat DOWN to lanes as `user_message`. Presence = the lane heartbeat.
    * **User plane (the server)** — the human chat. An `agent_message` is relayed
      UP to the server (`HarnessProxySocket` → `CodeMySpecWeb.HarnessChannel`),
      persisted via `Conversations.add_agent_message/4`, and rendered in the
      operator inbox; a human reply comes back DOWN and is routed to a lane.

  This module is only the PubSub seam that decouples the channel from the
  Slipstream proxy, so each is independently testable:

    * `relay_up/2` — the channel broadcasts an agent's message toward the server;
      the per-account `HarnessProxySocket` is subscribed and pushes it over the
      wire. In tests you can `subscribe_relay/1` and assert the broadcast without
      any server.
    * `route_to_lane/4` — deliver an event (work, human chat, `wake`, `abort`) to
      one lane's own channel, which `push`es it down its socket.

  Its own top-level Boundary: the `WorkSource` reuses the `McpServers`
  requirement-resolution path (as `get_next_requirement` does), which the plain
  `CodeMySpec` boundary may not reference.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec, CodeMySpec.McpServers, CodeMySpec.Environments, CodeMySpec.Repo],
    exports: :all

  @pubsub CodeMySpec.PubSub

  @doc "Topic one lane's channel listens on for events targeted at it."
  def lane_topic(external_id, role), do: "harness:session:#{external_id}:role:#{role}"

  @doc "Topic the per-account proxy listens on for messages headed to the server."
  def relay_topic(account_id), do: "harness:relay:#{account_id}"

  @doc "Broadcast an agent message toward the server (picked up by `HarnessProxySocket`)."
  def relay_up(account_id, payload) do
    Phoenix.PubSub.broadcast(@pubsub, relay_topic(account_id), {:relay_up, "agent_message", payload})
  end

  @doc "Deliver `event`/`payload` to a single lane's channel."
  def route_to_lane(external_id, role, event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, lane_topic(external_id, role), {:to_lane, event, payload})
  end

  @doc "Subscribe the caller (a lane's own channel) to its lane topic."
  def subscribe_lane(external_id, role), do: Phoenix.PubSub.subscribe(@pubsub, lane_topic(external_id, role))

  @doc "Subscribe the caller (the per-account proxy) to the account's relay topic."
  def subscribe_relay(account_id), do: Phoenix.PubSub.subscribe(@pubsub, relay_topic(account_id))
end
