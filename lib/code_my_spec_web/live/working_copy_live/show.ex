defmodule CodeMySpecWeb.WorkingCopyLive.Show do
  @moduledoc """
  One working copy: what it is, and every agent running on it.

  This is where the hierarchy is actually visible. The copy is the harness on
  somebody's machine; the agents are the lanes it started, told apart by role.
  The index can only summarise that ("2 agents present"); here each lane is its
  own row with its own engine, provider, process and evidence of life.

  ## One chat link per agent, named so they can be told apart

  A conversation belongs to an agent, so a copy running five of them has five
  transcripts and this lists five links.

  Named by the conversation, not by the agent's role. The role was the obvious
  handle and it is not unique: `start_agent` takes no role, so every agent
  started that way is "main" and a copy running two of them showed two links
  reading "Open main chat", one above the other. They went to different
  conversations, which is worse than it sounds — an operator who picks the
  wrong one has redirected the agent they were not watching, and nothing on
  either page says so. A conversation's generated name is unique and already on
  the page it leads to. It used to be one link per copy,
  keyed `pi:<root>`, from when a copy ran one lane — with several, their turns
  interleaved into one thread and a single link could only open the one nobody
  had asked for.

  A link appears only where a conversation exists. A Claude Code agent has no
  lane to route a message to, so offering its chat would accept text and drop
  it — worse than offering nothing, because the person believes they redirected
  an agent and finds out when the work comes back wrong.

  ## Still nothing that ends anything

  No stop, for an agent or for a harness. `os_pid` is shown because it is how
  somebody goes and looks on the box that owns the process — which is where the
  lifecycle lives.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.WorkingCopies
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

        {:noreply, socket |> assign(:working_copy_id, id) |> load(project)}
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
    |> Rows.get(project, socket.assigns.working_copy_id, now)
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

  # Designating this checkout as the one the project's own agent runs in.
  #
  # Re-reads the row rather than patching the one in assigns: designating
  # clears whichever copy held it before, so the page's own idea of the project
  # is stale the moment this returns.
  @impl true
  def handle_event("designate_main", _params, socket) do
    case WorkingCopies.designate_main(
           socket.assigns.current_scope,
           socket.assigns.working_copy_id
         ) do
      {:ok, _copy} ->
        {:noreply, load(socket, socket.assigns.project)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That working copy is not on this project.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "That copy could not be made the main one. Try again.")}
    end
  end

  # The chat is only an offer where there is something on the other end of it.
  #
  # What an agent started here can look at, in the words somebody would use.
  #
  # On the page because the failing case is invisible everywhere else: a machine
  # whose vibium will not answer reports the same empty list as a machine with no
  # vibium, and an agent there is recorded with its tools, none of which can look
  # at a page. Until this existed the only record was a warning in the harness
  # log — issue 02b03d04.
  defp browser_label(%{browser_status: "ready"} = harness),
    do: "#{length(harness.machine_tools || [])} browser tools"

  defp browser_label(%{browser_status: "absent"}), do: "No browser on this machine"

  defp browser_label(%{browser_status: "unreachable"}),
    do: "Installed, and did not answer — agents here cannot look at a page"

  defp browser_label(_), do: "Not reported"

  # `:running`, not merely `:pi` — the same mistake `Liveness` made, one panel
  # further down the page. Gating on engine alone offered "Open agent chat" for
  # a lane that had not confirmed, so the page said "no harness has confirmed
  # it" and then invited you to message it. The moduledoc above is the argument:
  # a box with no lane behind it accepts text and drops it, which is worse than
  # no box, and an *offer* to open one is the same promise one click earlier.
  defp chattable?(row), do: reachable_chats(row) != []

  # The lanes a message would actually reach, and the only ones offered a
  # button.
  #
  # This existed as a predicate over the whole row while the buttons were drawn
  # from the unfiltered list, so the two disagreed and the page rendered both
  # halves of the disagreement: "Open agent chat" for a lane, and underneath it
  # "there is nothing joined to receive a message". One function now, because
  # the question "can this be talked to" has one answer per chat and the offer
  # and the explanation are the same decision seen from two sides.
  defp reachable_chats(%{chats: chats}) when is_list(chats),
    do: Enum.filter(chats, &(&1.agent.engine == :pi and &1.agent.status == :running))

  defp reachable_chats(_row), do: []

  # Why there is nothing to talk to, in the terms of this copy rather than in
  # general. "A Claude Code agent reports over hooks" is a true sentence and the
  # wrong one in front of somebody looking at a Pi lane that has not come up
  # yet — they would go and check the wrong thing.
  defp no_chat_reason(%{agents: []}), do: "Nothing is running on this copy to talk to."

  defp no_chat_reason(%{agents: agents}) do
    cond do
      Enum.any?(agents, &(&1.engine == :pi and &1.status == :starting)) ->
        "This copy's Pi lane has not confirmed yet. There is nothing joined to " <>
          "receive a message, so the chat opens once the harness reports it."

      true ->
        "No lane to talk to on this copy. A Claude Code agent reports over hooks " <>
          "and has no channel to receive a reply on."
    end
  end

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
            <%!-- Shown only where it would do something. A control that says
            "make this the main copy" over the copy that already is reads as
            though the designation had not taken. --%>
            <.button
              :if={not @row.harness.main}
              phx-click="designate_main"
              data-test="designate-main-copy"
              class="btn btn-sm"
            >
              <.icon name="hero-star" /> Make this the main copy
            </.button>
            <span
              :if={@row.harness.main}
              data-test="main-copy"
              class="badge badge-primary gap-1"
            >
              <.icon name="hero-star-solid" class="size-3" /> Main checkout
            </span>
          </:actions>
        </.header>

        <.list>
          <:item title="Working copy id">{@row.harness.id}</:item>
          <:item title="Root">{@row.harness.root}</:item>
          <:item title="Working copy last seen">
            {Liveness.since(@row.harness.last_seen_at, @now) || "not yet"}
          </:item>
          <:item title="Liveness">
            <span data-test="liveness">
              {@row.liveness.label}
              <span :if={@row.liveness.since} data-test="liveness-since">{@row.liveness.since}</span>
            </span>
            <div data-test="liveness-basis" class="text-xs opacity-60">{@row.liveness.basis}</div>
          </:item>
          <:item title="Browser">
            <span data-test="browser-status">{browser_label(@row.harness)}</span>
            <div
              :if={@row.harness.browser_error}
              data-test="browser-error"
              class="text-xs opacity-60"
            >
              {@row.harness.browser_error}
            </div>
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
            Each agent on this copy has its own transcript, which is where you watch it
            work and talk back to it.
          </p>

          <div
            :for={chat <- reachable_chats(@row)}
            class="mt-3 flex items-center gap-3"
            data-test="agent-chat"
          >
            <.button
              navigate={~p"/app/projects/#{@project.id}/agent-conversation/#{chat.conversation.id}"}
              data-test="open-agent-chat"
              class="btn btn-sm btn-primary"
            >
              Open {Conversations.display_name(chat.conversation)}
            </.button>
            <span class="text-xs opacity-60">
              {chat.agent.role} · {chat.message_count} messages<span :if={chat.last_message_at}>, last {Liveness.since(chat.last_message_at, @now)}</span>
            </span>
          </div>

          <p :if={not chattable?(@row)} data-test="no-agent-chat" class="mt-3 text-sm opacity-60">
            {no_chat_reason(@row)}
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
