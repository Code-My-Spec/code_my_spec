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
    deps: [
      CodeMySpec,
      CodeMySpec.McpServers,
      CodeMySpec.Environments,
      CodeMySpec.Projects,
      CodeMySpec.Repo
    ],
    exports: :all

  @pubsub CodeMySpec.PubSub

  @doc "Topic one lane's channel listens on for events targeted at it."
  def lane_topic(external_id, role), do: "harness:session:#{external_id}:role:#{role}"

  @doc "Topic the per-account proxy listens on for messages headed to the server."
  def relay_topic(account_id), do: "harness:relay:#{account_id}"

  @doc """
  Topic every lane on this account is tracked on, in addition to its own.

  Presence has no "list all topics", and the set of lanes is exactly what the
  server needs to be told. Tracking each lane a second time on one per-account
  topic makes that set a single `Presence.list/1` — still Presence, so a lane
  still leaves it by its process dying and nothing has to expire.

  Read by `CodeMySpecLocalWeb.LaneReporter`, which outlives every lane. That
  matters: the report is a whole-set reconcile, and the moment that has to be
  reported is the *last* lane going away — when no lane channel is left to
  report it. It lives over there rather than in the proxy because Presence
  belongs to the local web app and this boundary may not reference it.
  """
  def lanes_topic(account_id), do: "harness:lanes:#{account_id}"

  @doc "Broadcast an agent message toward the server (picked up by `HarnessProxySocket`)."
  def relay_up(account_id, payload), do: relay_event(account_id, "agent_message", payload)

  @doc """
  Broadcast any event toward the server on the account's relay topic.

  `relay_up/2` was the whole surface while a transcript line was the only thing
  going up. `agents_running` is the second, and the proxy already pushes
  whatever event it is handed — the hardcoded name was the only thing stopping
  a second producer existing.
  """
  def relay_event(account_id, event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, relay_topic(account_id), {:relay_up, event, payload})
  end

  @doc """
  Ask whoever composes the running-agents report to send one now.

  The socket is up and may have missed changes while it was down. Pushes are
  dropped rather than queued while disconnected, so without this the server
  keeps whatever it last heard until a lane happens to move — which for an
  idle-but-alive box is never.
  """
  def request_report(account_id) do
    Phoenix.PubSub.broadcast(@pubsub, lanes_topic(account_id), :report_running)
  end

  @doc "Deliver `event`/`payload` to a single lane's channel."
  def route_to_lane(external_id, role, event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, lane_topic(external_id, role), {:to_lane, event, payload})
  end

  @doc "Subscribe the caller (a lane's own channel) to its lane topic."
  def subscribe_lane(external_id, role),
    do: Phoenix.PubSub.subscribe(@pubsub, lane_topic(external_id, role))

  @doc "Subscribe the caller (the per-account proxy) to the account's relay topic."
  def subscribe_relay(account_id), do: Phoenix.PubSub.subscribe(@pubsub, relay_topic(account_id))
end
