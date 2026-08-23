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
  alias CmsHarness.HarnessConfig

  # A lane declares itself on join. `role` is required and always has been;
  # `engine` and `provider` are what it is and what is paying for it, and a lane
  # is the only thing that knows either.
  #
  # They default because identity used to be a property of the *session* — one
  # Claude Code agent per checkout, so "the session" and "the agent" were the
  # same thing and neither needed saying. A Pi session is a team, and the
  # defaults are what a lane that has not caught up with that still reports.
  @impl true
  def join("harness:session:" <> external_id, %{"role" => role} = params, socket) do
    socket =
      assign(socket,
        external_id: external_id,
        role: role,
        engine: params["engine"] || "pi",
        provider: params["provider"] || "unknown"
      )

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
    root = working_copy(external_id)

    {:ok, _ref} =
      Presence.track(socket, role, %{
        online_at: System.system_time(:second),
        external_id: external_id
      })

    # Tracked a second time on the account's lanes topic, so the whole set of
    # lanes is one `Presence.list/1` for the proxy that reports it upward.
    # Without this the server has no way to learn what is running: it has always
    # had an `agents_running` handler and nothing has ever pushed one, so every
    # working copy read as idle no matter how many agents were on it.
    {:ok, _ref} =
      Presence.track(
        self(),
        AgentHarness.lanes_topic(socket.assigns.account_id),
        lane_key(socket),
        %{
          external_id: external_id,
          role: role,
          working_copy: root,
          harness_id: harness_id(root),
          engine: socket.assigns.engine,
          provider: socket.assigns.provider,
          online_at: System.system_time(:second)
        }
      )

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

  # One key per lane rather than per session. Presence keeps a meta per tracking
  # process either way, so this does not change what gets reported — it makes
  # `Presence.list/1` on the lanes topic readable as "the lanes", which is what
  # it is, instead of a session holding an unexplained list.
  defp lane_key(%{assigns: %{external_id: external_id, role: role}}),
    do: "#{external_id}|#{role}"

  # A Pi lane's session id is `pi:<cwd>`, and the working copy is the cwd. Said
  # here rather than on the server so the report carries the same root the
  # harness registered the checkout under, instead of a path reconstructed from
  # a key at the other end.
  defp working_copy("pi:" <> root), do: root
  defp working_copy(external_id), do: external_id

  # Which working copy this is, by the id the server issued it.
  #
  # Read from the checkout's own `.cms_harness.json` — the device wrote that
  # file and is the only party that knows which of several identically-rooted
  # harness rows this directory actually is. The server used to match the
  # reported path against `harnesses.root`, comparing two independently
  # produced strings and going wrong on a symlink, a trailing slash, or a root
  # that names more than one row.
  #
  # `nil` when the copy has not been onboarded. The report still goes up and the
  # server refuses that entry loudly, which is a better outcome than attaching
  # an agent to a copy chosen by a path match.
  defp harness_id(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{harness_id: id}} -> id
      _ -> nil
    end
  end
end
