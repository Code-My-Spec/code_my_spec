defmodule CodeMySpecWeb.WorkingCopyLive.Show do
  @moduledoc """
  One working copy: what it is, and every agent on it, each its own row with
  engine, provider, process and evidence of life. Also staffing, the copy's
  continuous switch, designating the main copy, and its story/epic queue.

  One chat link per agent conversation, named by the conversation
  (`Conversations.display_name/1`), not the role: roles are not unique on a
  copy. A link is offered only for an on-duty Alloy agent (`reachable_chats/1`);
  a Claude Code agent has no channel to receive a reply.

  Firing an agent (criterion 2207) retires it for good -- its seat is freed
  and its conversation stays readable. There is still no control here for a
  harness itself. `os_pid` is shown so somebody can look on the box that owns
  the process.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.Staffing
  alias CodeMySpec.Stories
  alias CodeMySpecWeb.AgentLoopBadge
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
          Agents.subscribe_presence(socket.assigns.current_scope)
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

  # An agent's process came up or went down (`Agents.Presence`).
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket, socket.assigns.project)}

  # Re-render on a timer too: liveness lines are elapsed time computed at render.
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, load(socket, socket.assigns.project)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Every 30s; faster would invent precision the facts do not have.
  defp schedule_tick, do: Process.send_after(self(), :tick, :timer.seconds(30))

  defp main_copy_refusal?({_role, {:main_copy_occupied, _role_name, _root}}), do: true
  defp main_copy_refusal?({_role, {:not_at_home, _role_name, _root}}), do: true
  defp main_copy_refusal?(_failure), do: false

  # Not an error. The main checkout holds the main and product agents, one each;
  # coding and QA work on feature copies.
  defp main_copy_note([]),
    do:
      "This is the project's main checkout, which holds the main and product agents " <>
        "only, so nothing was started. Staff a different checkout for coding and QA."

  defp main_copy_note(started),
    do:
      "Started #{roster(started)}. This is the project's main checkout, which holds " <>
        "the main and product agents only, so the other roles were not started. Staff " <>
        "a different checkout for coding and QA."

  defp staffing_result(report, socket) do
    left_off = left_off(Map.get(report, :off, []))

    case report do
      %{started: [], failed: []} when left_off != "" ->
        {:noreply, put_flash(socket, :info, String.trim(left_off))}

      %{started: [], failed: []} ->
        {:noreply, put_flash(socket, :info, "Every role is already staffed on this copy.")}

      %{started: started, failed: []} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Started #{roster(started)}. Put them to work when you are ready.#{left_off}"
         )
         |> load(socket.assigns.project)}

      %{started: started, failed: failed} ->
        {:noreply,
         socket
         |> put_flash(:error, staffing_trouble(started, failed) <> left_off)
         |> load(socket.assigns.project)}
    end
  end

  # A role somebody turned off is skipped, and said so.
  defp left_off([]), do: ""

  defp left_off(agents) do
    " " <>
      Enum.map_join(agents, " ", fn agent ->
        reason = if agent.off_reason, do: ": #{agent.off_reason}", else: ""

        "#{String.capitalize(to_string(agent.role))} is off (by #{agent.off_by}#{reason}), left alone."
      end)
  end

  # Understaffed when a seat is truly empty. An off agent holds its seat (and
  # `ensure_copy_agents/2` skips it), so the button shows only when it would act.
  defp understaffed?(copy, agents, off),
    do: Agents.empty_seats(agents ++ off, Agents.home_roles(copy)) != []

  # Main and product on the main copy, coding and QA elsewhere.
  defp home_roles_text(copy),
    do: copy |> Agents.home_roles() |> Enum.map_join(" and ", &role_name/1)

  defp role_name(:qa), do: "QA"
  defp role_name(role), do: to_string(role)

  defp roster(agents) do
    case Enum.map(agents, &to_string(&1.role)) do
      [one] -> "a #{one} agent"
      roles -> "#{length(roles)} agents — #{Enum.join(roles, ", ")}"
    end
  end

  defp staffing_trouble([], failed),
    do: "Could not staff this copy: " <> failures(failed)

  defp staffing_trouble(started, failed),
    do: "Started #{roster(started)}, but " <> failures(failed)

  defp failures(failed),
    do: Enum.map_join(failed, "; ", fn {role, reason} -> "#{role} — #{inspect(reason)}" end)

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
    off =
      socket.assigns.current_scope
      |> Agents.off_agents()
      |> Enum.filter(&(&1.working_copy_id == row.harness.id))

    socket
    |> assign(:row, row)
    |> assign(:off_agents, off)
    |> assign(
      :queued_stories,
      Enum.filter(
        Stories.list_stories(socket.assigns.current_scope),
        &(&1.working_copy_id == row.harness.id)
      )
    )
    |> assign(:queue_epics, Epics.list_epics(socket.assigns.current_scope))
    |> assign(:now, now)
    |> assign(:page_title, row.heading)
    # `assign_new`: this function reruns on every tick and every agent event,
    # and a plain `assign` here would disarm the confirmation under someone's
    # hand the moment anything else on the copy so much as reported in.
    |> assign_new(:armed_agent_id, fn -> nil end)
  end

  @impl true
  def handle_event("add_story_to_queue", %{"queue" => %{"story_number" => number}}, socket),
    do: edit_story_queue(socket, number, :add)

  def handle_event("remove_story_from_queue", %{"story_number" => number}, socket),
    do: edit_story_queue(socket, number, :remove)

  def handle_event("add_epic_to_queue", %{"queue" => %{"epic_id" => id}}, socket),
    do: edit_queue(socket, :epic, id, :add)

  def handle_event("remove_epic_from_queue", %{"epic_id" => id}, socket),
    do: edit_queue(socket, :epic, id, :remove)

  # Arms the in-page confirmation rather than acting immediately -- firing
  # retires the agent for good, freeing its seat, unlike the stop criteria
  # 970-978 cover, which only ever ends the one process.
  def handle_event("fire_agent", %{"id" => id}, socket) do
    {:noreply, assign(socket, :armed_agent_id, id)}
  end

  def handle_event("cancel_fire_agent", _params, socket) do
    {:noreply, assign(socket, :armed_agent_id, nil)}
  end

  def handle_event("confirm_fire_agent", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Agents.retire_agent(scope, id, by: Agents.actor(scope)) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> assign(:armed_agent_id, nil)
         |> load(socket.assigns.project)
         |> put_flash(:info, "Agent fired.")}

      {:ok, _agent, {:unreachable, _machine}} ->
        {:noreply,
         socket
         |> assign(:armed_agent_id, nil)
         |> load(socket.assigns.project)
         |> put_flash(
           :info,
           "Agent fired; its machine could not be reached to end the process."
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:armed_agent_id, nil)
         |> put_flash(:error, "That agent could not be fired. Try again.")}
    end
  end

  # Makes this the checkout the project's own agent runs in. Reloads: the
  # previous main copy was cleared.
  def handle_event("designate_main", _params, socket) do
    case Staffing.designate_main(
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

  # Idempotent: `ensure_copy_agents/2` skips any role already live. Both what
  # started and what failed are reported.
  def handle_event("staff_copy", _params, socket) do
    scope = socket.assigns.current_scope

    case Agents.ensure_copy_agents(scope, socket.assigns.row.harness) do
      # A main-copy refusal is said in words, not as an inspected tuple.
      %{failed: [_ | _] = failed} = report ->
        if Enum.all?(failed, &main_copy_refusal?/1) do
          {:noreply,
           socket
           |> put_flash(:info, main_copy_note(report.started))
           |> load(socket.assigns.project)}
        else
          staffing_result(report, socket)
        end

      report ->
        staffing_result(report, socket)
    end
  end

  # Put the whole copy to work, or let it stop. The direction comes from the
  # agents' rows, not an assign.
  def handle_event("toggle_working", _params, socket) do
    scope = socket.assigns.current_scope
    working? = working?(socket.assigns.row.agents)

    case Agents.set_copy_continuous(scope, socket.assigns.working_copy_id, not working?) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :error, "Nothing is running on this copy to put to work.")}

      {:ok, _count} ->
        {:noreply, load(socket, socket.assigns.project)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That could not be changed. Try again.")}
    end
  end

  # Working when any agent is, not all: roles may diverge (coding can stop when
  # its work runs out while product carries on).
  defp working?(agents), do: Enum.any?(agents, &(&1.continuous == true))

  defp edit_story_queue(socket, number, action) do
    case Integer.parse(to_string(number)) do
      {number, ""} -> edit_queue(socket, :story, number, action)
      _ -> {:noreply, put_flash(socket, :error, "Choose a valid story number.")}
    end
  end

  defp edit_queue(socket, kind, subject, action) do
    case EpicDispatch.edit_queue(
           socket.assigns.current_scope,
           kind,
           subject,
           socket.assigns.working_copy_id,
           action
         ) do
      {:ok, _count} ->
        {:noreply, load(socket, socket.assigns.project)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update this copy's queue.")}
    end
  end

  # What an agent started here can look at. Shown because "installed but not
  # answering" reports the same empty tool list as "absent" everywhere else.
  defp browser_label(%{browser_status: "ready"} = harness),
    do: "#{length(harness.machine_tools || [])} browser tools"

  defp browser_label(%{browser_status: "absent"}), do: "No browser on this machine"

  defp browser_label(%{browser_status: "unreachable"}),
    do: "Installed, and did not answer — agents here cannot look at a page"

  defp browser_label(_), do: "Not reported"

  # The offer and the "nothing to talk to" explanation are one decision.
  defp chattable?(row), do: reachable_chats(row) != []

  # Alloy agents nobody turned off or retired. Reachability is not asked: an
  # unreachable agent still gets a box, and `Agents.dispatch_message/3` reports
  # the failure.
  # See knowledge/web, "Agent conversation".
  defp reachable_chats(%{chats: chats}) when is_list(chats),
    do: Enum.filter(chats, &(&1.agent.engine == :alloy and Agents.on_duty?(&1.agent)))

  defp reachable_chats(_row), do: []

  # Why there is nothing to talk to, in this copy's terms.
  defp no_chat_reason(%{agents: []}), do: "Nothing is running on this copy to talk to."

  defp no_chat_reason(%{agents: _agents}) do
    "No lane to talk to on this copy. A Claude Code agent reports over hooks " <>
      "and has no channel to receive a reply on."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
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

        <section class="my-6 space-y-4" data-test="working-copy-queue">
          <h2 class="text-lg font-semibold">Queued work</h2>
          <form phx-submit="add_story_to_queue" data-test="add-story-to-queue" class="flex gap-2">
            <label>
              Story number
              <input name="queue[story_number]" type="number" required class="input input-sm" />
            </label>
            <button type="submit" class="btn btn-sm">Add story</button>
          </form>
          <form phx-submit="add_epic_to_queue" data-test="add-epic-to-queue" class="flex gap-2">
            <label>
              Epic
              <select name="queue[epic_id]" required class="select select-sm">
                <option value="">Choose an epic</option>
                <option :for={epic <- @queue_epics} value={epic.id}>{epic.name}</option>
              </select>
            </label>
            <button type="submit" class="btn btn-sm">Add epic</button>
          </form>
          <div :for={epic <- @queue_epics} :if={Enum.any?(@queued_stories, &(&1.epic_id == epic.id))}>
            <span>{epic.name}</span>
            <button
              phx-click="remove_epic_from_queue"
              phx-value-epic_id={epic.id}
              data-test="remove-epic-from-queue"
              data-epic-id={epic.id}
              class="btn btn-sm btn-ghost"
            >
              Remove epic
            </button>
          </div>
          <div
            :for={story <- @queued_stories}
            data-test="queued-story"
            data-story-number={story.number}
          >
            <span>{story.number}: {story.title}</span>
            <button
              phx-click="remove_story_from_queue"
              phx-value-story_number={story.number}
              data-test="remove-story-from-queue"
              data-story-number={story.number}
              class="btn btn-sm btn-ghost"
            >
              Remove story
            </button>
          </div>
          <p :if={@queued_stories == []}>No stories queued.</p>
        </section>

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

        <%!-- Agents and their transcripts used to be two sections — a list of
        lanes, then underneath it a second list of the same lanes' chat
        links, told apart only by matching role text between them. One list
        now: a lane's transcript, when it has one, sits inside its own card
        rather than in a lookup exercise further down the page. --%>
        <section class="mt-8">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-lg font-semibold">Agents on this copy</h2>

            <%!-- Story 538's R13. Continuous mode decides whether these agents
            keep working when a turn ends, and until this it had no switch: the
            only way in was an agent happening to work the start_implementation
            task, and the only way out was tap_out, which asks a human. --%>
            <div class="flex items-center gap-2">
              <%!-- Staffing had no button. It happened as a side effect of
              minting a copy or of dispatching an epic onto one, so an existing,
              onboarded, unstaffed copy — which is an ordinary state — had no
              route at all. The only control here was "Put to work", which flips
              a flag on *running* agents and answers "Nothing is running on this
              copy to put to work" when there are none. The one action needed
              agents to already exist.

              John, looking at a copy with 45 stopped agents on it: "I know it's
              onboarded properly, it has no agents. How do I get my agents?"

              Shown whenever a role is missing rather than only when the list is
              empty: a copy running QA and nothing else is short two agents, and
              `ensure_copy_agents/2` skips the roles already live. --%>
              <.button
                :if={understaffed?(@row.harness, @row.agents, @off_agents)}
                type="button"
                phx-click="staff_copy"
                data-test="staff-copy"
                class="btn btn-sm btn-primary"
              >
                Staff it
              </.button>

              <span :if={@row.agents != []} data-test="loop-state" class="text-xs opacity-70">
                {if working?(@row.agents),
                  do: "Working — each agent picks its own next task",
                  else: "Idle — agents stop at the end of a turn"}
              </span>
              <.button
                :if={@row.agents != []}
                type="button"
                phx-click="toggle_working"
                data-test="toggle-working"
                class="btn btn-sm"
              >
                {if working?(@row.agents), do: "Let them stop", else: "Put to work"}
              </.button>
            </div>
          </div>

          <%!-- What to do about it, not just that it is so. The old text said
          "Nothing is running on this copy." and stopped there, which is the
          sentence that sent somebody looking for a control that does not
          exist. --%>
          <p :if={@row.agents == []} data-test="no-agents" class="py-10 text-center opacity-60">
            Nothing is running on this copy. <strong>Staff it</strong>
            starts its {home_roles_text(@row.harness)} agents in this checkout.
            <span :if={not @row.harness.main}>
              Approving an epic onto a copy does the same thing.
            </span>
          </p>

          <%!-- `data-agent-id` carries identity, not just role. "The same three
          took the next epic" and "three agents are here" are different claims,
          and only the first says a second epic cost nothing to staff — which is
          the whole reason a copy's roster belongs to the copy rather than to the
          work. Story 964's criterion 3090 cannot tell them apart without it. --%>
          <ul class="mt-4 space-y-2">
            <li
              :for={agent <- @row.agents}
              data-test="agent"
              data-role={agent.role}
              data-agent-id={agent.id}
              data-engine={agent.engine}
              class="card card-compact border border-base-300 bg-base-100"
            >
              <div class="card-body gap-2">
                <div class="flex items-center gap-3">
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium">{agent.role}</span>
                      <AgentLoopBadge.loop_badge continuous?={agent.continuous == true} />
                    </div>
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

                <div
                  :if={chat_for(@row, agent)}
                  class="flex items-center gap-3 border-t border-base-300 pt-2"
                  data-test="agent-chat"
                >
                  <.button
                    navigate={
                      ~p"/app/projects/#{@project.id}/agent-conversation?#{[conversation: chat_for(@row, agent).conversation.id]}"
                    }
                    data-test="open-agent-chat"
                    class="btn btn-xs btn-primary"
                  >
                    Open {Conversations.display_name(chat_for(@row, agent).conversation)}
                  </.button>
                  <span class="text-xs opacity-60">
                    {chat_for(@row, agent).message_count} messages<span :if={
                      chat_for(@row, agent).last_message_at
                    }>, last {Liveness.since(chat_for(@row, agent).last_message_at, @now)}</span>
                  </span>
                </div>

                <div
                  :if={@armed_agent_id != agent.id}
                  class="flex items-center gap-2 border-t border-base-300 pt-2"
                >
                  <.button
                    type="button"
                    phx-click="fire_agent"
                    phx-value-id={agent.id}
                    data-test="fire-agent"
                    class="btn btn-xs btn-error btn-outline"
                  >
                    Fire
                  </.button>
                </div>

                <div
                  :if={@armed_agent_id == agent.id}
                  class="flex flex-wrap items-center gap-2 border-t border-base-300 pt-2 text-sm"
                >
                  <span data-test="fire-agent-confirm-text">
                    Fire the {agent.role} agent? This cannot be undone.
                  </span>
                  <.button
                    type="button"
                    phx-click="confirm_fire_agent"
                    phx-value-id={agent.id}
                    data-test="confirm-fire-agent"
                    class="btn btn-xs btn-error"
                  >
                    Fire
                  </.button>
                  <.button
                    type="button"
                    phx-click="cancel_fire_agent"
                    data-test="cancel-fire-agent"
                    class="btn btn-xs btn-ghost"
                  >
                    Cancel
                  </.button>
                </div>
              </div>
            </li>
          </ul>

          <p
            :if={not chattable?(@row)}
            data-test="no-agent-chat"
            class="mt-3 text-sm opacity-60"
          >
            {no_chat_reason(@row)}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp chat_for(row, agent), do: Enum.find(row.chats, &(&1.agent.id == agent.id))

  defp engine_name(:alloy), do: "Alloy"
  defp engine_name(:claude_code), do: "Claude Code"
  defp engine_name(:codex), do: "Codex"
  defp engine_name(other), do: to_string(other)
end
