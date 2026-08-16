defmodule CodeMySpecWeb.AgentConversationLive.Show do
  @moduledoc """
  Read-only view of one agent session's conversation — the turns it took, the
  tools it called and what they returned, with sub-agent turns attributed to the
  sub-agent via `agent_role`. New turns arrive live while the agent runs, with
  no reload and nothing the operator can send back.

  One page is one **session**, taken from the URL. It used to be "whichever
  conversation for this project moved most recently", which reads as *the*
  conversation while a project has one agent and silently hides four when it has
  five — and changes under you as they take turns. `Index` lists them.

  Deliberately separate from `InboxLive`: that is a support queue where a person
  is writing to the operator; this is a machine being watched. Agent
  conversations never appear in `Conversations.list_conversations/1` or count
  toward `Conversations.unread_count/1`, so watching an agent never raises the
  support inbox's unread badge.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpecWeb.ChatComponents

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  # One page of turns. 50 is `Conversations.@default_page_size`; named here too
  # because the loader compares against it to decide whether more sit above.
  @page 50

  defp messages_for(nil), do: []
  defp messages_for(conversation), do: Conversations.list_messages(conversation, limit: @page)

  # The project comes off the scope, not out of a lookup here: `PortableHost`
  # resolves `:project_id` for every route in this live_session. It attaches on
  # `handle_params`, which is why this cannot run in `mount`.
  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      project ->
        {:noreply, mount_conversation(socket, project, params["conversation_id"])}
    end
  end

  defp mount_conversation(socket, project, conversation_id) do
    scope = with_active_project(socket.assigns.current_scope, project)
    conversation = Conversations.get_agent_conversation_by_id(scope, conversation_id)
    messages = messages_for(conversation)

    if connected?(socket) && conversation do
      Phoenix.PubSub.subscribe(
        CodeMySpec.PubSub,
        Conversations.conversation_topic(conversation.id)
      )
    end

    socket
    |> assign(:current_scope, scope)
    |> assign(:project, project)
    |> assign(:conversation, conversation)
    |> assign(:page_title, page_title(project, conversation))
    |> assign(:recording_gap, conversation != nil and messages == [])
    |> assign(:questions, questions_for(conversation))
    |> assign_more_above(messages, @page)
    |> assign_turns(messages)
  end

  defp page_title(project, nil), do: "#{project.name} · Agent conversation"

  defp page_title(project, conversation),
    do: "#{project.name} · #{Conversations.display_name(conversation)}"

  # The id stays visible beside the name: the name is a handle someone chose,
  # and the session id is what appears in the logs you would go read next.
  defp short_session(%{session_external_id: id}) when is_binary(id) do
    case String.split(id, "-") do
      [first | _] when byte_size(first) == 8 -> first
      _ -> String.slice(id, 0, 16)
    end
  end

  defp short_session(_), do: ""

  # `active_project_id` is what `Conversations.get_agent_conversation/2` scopes
  # on, so both fields are set together — otherwise the page for one project
  # could read another project's turns off a stale `active_project_id`.
  defp with_active_project(scope, project),
    do: %{scope | active_project: project, active_project_id: project.id}

  # The questions this session asked. They belong here rather than only on a
  # page of their own: a question read without the work that prompted it is a
  # question you cannot answer well.
  @impl true
  def handle_event("answer_question", params, socket) do
    # The submitted form does not name which question it was; a conversation can
    # hold several, and only one is ever pending, so that is the one being
    # answered. Answered ones render without a form.
    case Enum.find(socket.assigns.questions, &(&1.status == "pending")) do
      nil ->
        {:noreply, socket}

      request ->
        answers = Notifications.collect_answers(request.questions, params)
        _ = Notifications.answer_question_request(request.id, answers)

        {:noreply, assign(socket, :questions, questions_for(socket.assigns.conversation))}
    end
  end

  # Older turns, when the operator reaches the top.
  #
  # A transcript is 1,572 messages on a session that has run all day, and the
  # page loads fifty — so everything before the last fifty was unreachable.
  # `list_messages/2` already took a `:before` cursor and simply had no caller.
  #
  # Prepends, and re-folds the whole list: a run of calls is grouped by looking
  # at neighbours, so an older page arriving can legitimately join a run that is
  # already on screen.
  def handle_event("load_older", _params, %{assigns: %{conversation: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_older", _params, socket) do
    case socket.assigns.messages do
      [] ->
        {:noreply, socket}

      [oldest | _] ->
        older =
          Conversations.list_messages(socket.assigns.conversation,
            limit: @page,
            before: oldest.inserted_at
          )

        {:noreply,
         socket
         |> assign_more_above(older, @page)
         |> assign_turns(older ++ socket.assigns.messages)}
    end
  end

  defp questions_for(nil), do: []

  defp questions_for(conversation),
    do: Notifications.list_question_requests_for_session(conversation.session_external_id)

  # A plain assign, not a stream.
  #
  # Two things here need to see a message's neighbours: folding a run of calls
  # into one item, and nesting a result inside the call it answers. A result
  # arrives a *turn* after its call, so it has to join something already
  # rendered — and a stream cannot do that. `stream_insert/3` appends without
  # reordering, and a group's dom id is its first message's id, so streaming
  # that id back would replace the whole group with a single turn.
  #
  # The page holds one page of messages (50 by default), so re-folding the list
  # on each arrival costs nothing and the whole class of problem goes away.
  defp assign_turns(socket, messages) do
    {items, results} = ChatComponents.group_turns(messages)

    socket
    |> assign(:messages, messages)
    |> assign(:items, items)
    |> assign(:results, results)
  end

  # A full page back means there is probably more; a short one means we reached
  # the beginning. Assumed true before the first fetch so the binding is armed
  # on a conversation that is exactly one page long — the check costs one query
  # and being wrong the other way means the operator can never reach the top.
  defp assign_more_above(socket, fetched, limit),
    do: assign(socket, :more_above?, length(fetched) >= limit)

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, assign_turns(socket, socket.assigns.messages ++ [message])}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- Render -----------------------------------------------------------------

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
        data-test="agent-conversation"
        data-project-id={@project.id}
        style="height: calc(100dvh - 7rem)"
        class="mx-auto flex w-full max-w-3xl flex-col"
      >
        <header class="flex shrink-0 items-center gap-2 border-b border-base-300 pb-3">
          <.link
            navigate={~p"/app/projects/#{@project.id}/agent-conversation"}
            class="btn btn-ghost btn-sm btn-square"
            title="All agents"
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <.icon name="hero-cpu-chip" class="size-5 shrink-0" />
          <h1 class="min-w-0 truncate text-lg font-semibold">
            {@conversation && Conversations.display_name(@conversation)}
          </h1>
          <span :if={@conversation} class="shrink-0 font-mono text-xs opacity-40">
            {short_session(@conversation)}
          </span>
        </header>

        <%!-- `overflow-anchor` is what keeps your place when older turns are
              prepended: without it the browser holds the scroll *offset*, so
              inserting above jumps you backwards by exactly the height added.
              `StickToBottom` opens at the newest turn and follows it only while
              you are already down there. --%>
        <div
          id="agent-scroll"
          phx-hook="StickToBottom"
          class="min-h-0 flex-1 overflow-y-auto py-4"
          style="overflow-anchor: auto"
        >
          <p
            :if={@conversation == nil}
            data-test="agent-conversation-empty"
            class="py-8 text-center opacity-60"
          >
            No agent activity recorded for this project yet.
          </p>

          <p
            :if={@conversation != nil and @recording_gap}
            data-test="recording-gap"
            class="rounded-box border border-warning/40 bg-warning/10 p-3 text-sm"
          >
            Turns were taken but not recorded. What follows is incomplete —
            treat gaps as missing evidence, not as an idle sprite.
          </p>

          <div :if={@questions != []} data-test="conversation-questions" class="mb-4 space-y-3">
            <ChatComponents.question
              :for={request <- @questions}
              id={"question-#{request.id}"}
              request={request}
              on_submit="answer_question"
            />
          </div>

          <div
            id="agent-turns"
            class="space-y-2"
            phx-viewport-top={@more_above? && "load_older"}
            data-more-above={to_string(@more_above?)}
          >
            <p :if={@more_above?} data-test="loading-older" class="py-2 text-center text-xs opacity-40">
              loading earlier turns…
            </p>
            <ChatComponents.turn_item
              :for={item <- @items}
              id={"turn-#{item.id}"}
              item={item}
              results={@results}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
