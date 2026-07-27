defmodule CodeMySpecLocalWeb.HarnessChannel do
  @moduledoc """
  The data-plane channel for one background-agent session. Every agent process
  (manager + each lane) joins `harness:session:<external_id>` with its `role`.

    * **Presence = heartbeat.** A lane is "registered for role X" exactly while
      joined (Story 704 — replaces the polled subagent-TTL registry).
    * **Transcript → server.** `agent_message` is relayed UP via
      `CodeMySpec.AgentHarness.relay_up/2` to the server, which persists it on the
      session's conversation and renders it in the operator inbox. The local app
      keeps no conversation store — it is a pass-through.
    * **Work / chat → the right lane.** The manager's `dispatch` and human replies
      are broadcast on the target lane's topic; that lane's own channel `push`es
      them down as `user_message`.
    * **Advance the graph.** `lane_idle` notifies the `WorkSource`, which resolves
      the next requirement for the role and dispatches it.
  """

  use Phoenix.Channel

  alias CodeMySpec.AgentHarness
  alias CodeMySpec.AgentHarness.WorkSource
  alias CodeMySpecLocalWeb.Presence

  @impl true
  def join("harness:session:" <> external_id, %{"role" => role}, socket) do
    socket = assign(socket, external_id: external_id, role: role)
    # Each lane also listens on its own topic so cms can target it specifically.
    AgentHarness.subscribe_lane(external_id, role)
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("harness:session:" <> _external_id, _params, _socket),
    do: {:error, %{reason: "role required"}}

  @impl true
  def handle_info(:after_join, socket) do
    %{external_id: external_id, role: role} = socket.assigns

    {:ok, _ref} =
      Presence.track(socket, role, %{
        online_at: System.system_time(:second),
        external_id: external_id
      })

    {:noreply, socket}
  end

  # cms -> this lane: work item, human chat, wake, or abort.
  def handle_info({:to_lane, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # ---- Inbound from the harness (each agent, for itself) --------------------

  @impl true
  def handle_in("agent_message", %{"role" => role, "kind" => kind, "text" => text}, socket) do
    payload = %{
      "external_id" => socket.assigns.external_id,
      "project_id" => socket.assigns.scope.active_project_id,
      "role" => role,
      "kind" => kind,
      "text" => text
    }

    AgentHarness.relay_up(socket.assigns.account_id, payload)
    {:noreply, socket}
  end

  def handle_in("lane_idle", %{"role" => role}, socket) do
    WorkSource.lane_idle(socket.assigns.external_id, role)
    {:noreply, socket}
  end

  # Manager -> cms: route a work item to a lane. cms is the router; it forwards to
  # the target role's topic and that role's own channel pushes it as user_message.
  def handle_in("dispatch", %{"role" => role, "prompt" => prompt} = payload, socket) do
    interactive = payload["interactive"] == true
    if interactive, do: WorkSource.set_interactive(socket.assigns.external_id, role)

    AgentHarness.route_to_lane(socket.assigns.external_id, role, "user_message", %{
      "text" => prompt,
      "interactive" => interactive
    })

    {:noreply, socket}
  end

  # Optional/future — the Pi side does not emit these today; harmless no-ops.
  def handle_in("work_result", %{"role" => role} = payload, socket) do
    WorkSource.work_result(socket.assigns.external_id, role, payload)
    {:noreply, socket}
  end

  def handle_in("lane_busy", _payload, socket), do: {:noreply, socket}
  def handle_in(_event, _payload, socket), do: {:noreply, socket}
end
