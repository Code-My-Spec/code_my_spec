defmodule CodeMySpecWeb.WorkingCopyLive.Show do
  @moduledoc """
  One working copy: what it is, and every agent running on it.

  This is where the hierarchy is actually visible. The copy is the harness on
  somebody's machine; the agents are the lanes it started, told apart by role.
  The index can only summarise that ("2 agents present"); here each lane is its
  own row with its own engine, provider, process and evidence of life.

  ## The chat link belongs to the copy, not to the lane

  Every lane on a copy joins `harness:session:pi:<cwd>`, so one conversation
  holds the whole team's turns — `Agents.start_agent/2` and a Pi lane pushing
  `agent_message` both key on `pi:<root>`. Splitting the link per agent would
  promise five transcripts and open the same one five times.

  It appears only when a conversation exists and only for a copy with a Pi
  agent on it. A Claude Code agent has no lane to route a `user_message` to, so
  offering the chat would accept text and drop it — worse than offering
  nothing, because the person believes they redirected an agent and finds out
  when the work comes back wrong.

  ## Still nothing that ends anything

  No stop, for an agent or for a harness. `os_pid` is shown because it is how
  somebody goes and looks on the box that owns the process — which is where the
  lifecycle lives.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpecWeb.WorkingCopyLive.Liveness
  alias CodeMySpecWeb.WorkingCopyLive.Rows

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      project ->
        if connected?(socket) do
          Agents.subscribe(socket.assigns.current_scope)
          schedule_tick()
        end

        {:noreply, socket |> assign(:harness_id, id) |> load(project)}
    end
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:agents_reported, :agent_started, :agent_stopped] do
    {:noreply, load(socket, socket.assigns.project)}
  end

  # Re-render on a timer as well as on news. Every liveness line is elapsed
  # time computed at render, so a page that only redraws when an agent moves
  # shows "Running just now" for as long as nothing happens — the one reading
  # that cannot be true after the first minute.
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, load(socket, socket.assigns.project)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Matches `LaneReporter`'s heartbeat: redrawing faster than the facts arrive
  # invents precision the page does not have.
  defp schedule_tick, do: Process.send_after(self(), :tick, :timer.seconds(30))

  defp load(socket, project) do
    now = DateTime.utc_now()

    socket.assigns.current_scope
    |> Rows.get(project, socket.assigns.harness_id, now)
    |> assign_row(socket, now)
  end

  defp assign_row(nil, socket, _now) do
    socket
    |> put_flash(:error, "That working copy is not on this project.")
    |> push_navigate(to: ~p"/app/projects/#{socket.assigns.project.id}/working-copies")
  end

  defp assign_row(row, socket, now) do
    socket
    |> assign(:row, row)
    |> assign(:now, now)
    |> assign(:page_title, row.heading)
  end

  # The chat is only an offer where there is something on the other end of it.
  defp chattable?(%{conversation: nil}), do: false
  defp chattable?(%{agents: agents}), do: Enum.any?(agents, &(&1.engine == :pi))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_notifications={@pending_notifications}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div
        data-test="working-copy-show"
        data-root={@row.harness.root}
        class="mx-auto w-full max-w-3xl"
      >
        <.header>
          <span class="block break-all">{@row.heading}</span>
          <:subtitle>{@row.harness.root}</:subtitle>
          <:actions>
            <.button
              navigate={~p"/app/projects/#{@project.id}/working-copies"}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-arrow-left" /> All copies
            </.button>
            <.button
              navigate={~p"/app/projects/#{@project.id}/working-copies/#{@row.harness.id}/edit"}
              class="btn btn-sm"
              data-test="edit-working-copy"
            >
              <.icon name="hero-pencil-square" /> Rename
            </.button>
          </:actions>
        </.header>

        <.list>
          <:item title="Working copy id">{@row.harness.id}</:item>
          <:item title="Root">{@row.harness.root}</:item>
          <:item title="Harness last seen">
            {Liveness.since(@row.harness.last_seen_at, @now) || "not yet"}
          </:item>
          <:item title="Liveness">
            <span data-test="liveness">
              {@row.liveness.label}
              <span :if={@row.liveness.since} data-test="liveness-since">{@row.liveness.since}</span>
            </span>
            <div data-test="liveness-basis" class="text-xs opacity-60">{@row.liveness.basis}</div>
          </:item>
        </.list>

        <section class="mt-8">
          <h2 class="text-lg font-semibold">Agents on this copy</h2>
          <p class="mt-1 text-sm opacity-70">
            One row per lane. A copy runs one or more, and the harness tells them apart
            by role.
          </p>

          <p :if={@row.agents == []} data-test="no-agents" class="py-10 text-center opacity-60">
            Nothing is running on this copy.
          </p>

          <ul class="mt-4 space-y-2">
            <li
              :for={agent <- @row.agents}
              data-test="agent"
              data-role={agent.role}
              data-engine={agent.engine}
              class="card card-compact border border-base-300 bg-base-100"
            >
              <div class="card-body gap-1">
                <div class="flex items-center gap-3">
                  <div class="min-w-0 flex-1">
                    <div class="font-medium">{agent.role}</div>
                    <div class="text-xs opacity-60">
                      {engine_name(agent.engine)} · {agent.provider}
                      <span :if={agent.os_pid}>· pid {agent.os_pid}</span>
                    </div>
                  </div>

                  <div data-test="agent-liveness" class="shrink-0 text-right">
                    <div class="text-sm">
                      {Liveness.agent(agent, @now).label}
                      <span data-test="agent-liveness-since" class="opacity-70">
                        {Liveness.agent(agent, @now).since}
                      </span>
                    </div>
                    <div data-test="agent-liveness-basis" class="text-xs opacity-60">
                      {Liveness.agent(agent, @now).basis}
                    </div>
                  </div>
                </div>
              </div>
            </li>
          </ul>
        </section>

        <section class="mt-8">
          <h2 class="text-lg font-semibold">Transcript</h2>
          <p class="mt-1 text-sm opacity-70">
            Every lane on this copy writes to one conversation, which is where you talk
            back to them.
          </p>

          <div :if={chattable?(@row)} class="mt-3 flex items-center gap-3">
            <.button
              navigate={~p"/app/projects/#{@project.id}/agent-conversation/#{@row.conversation.id}"}
              data-test="open-agent-chat"
              class="btn btn-sm btn-primary"
            >
              Open agent chat
            </.button>
            <span class="text-xs opacity-60">
              {@row.message_count} messages<span :if={@row.last_message}>, last {@row.last_message}</span>
            </span>
          </div>

          <p :if={not chattable?(@row)} data-test="no-agent-chat" class="mt-3 text-sm opacity-60">
            No lane to talk to on this copy. A Claude Code agent reports over hooks and
            has no channel to receive a reply on.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp engine_name(:pi), do: "Pi"
  defp engine_name(:claude_code), do: "Claude Code"
  defp engine_name(other), do: to_string(other)
end
