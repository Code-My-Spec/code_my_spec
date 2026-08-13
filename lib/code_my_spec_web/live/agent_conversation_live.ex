defmodule CodeMySpecWeb.AgentConversationLive do
  @moduledoc """
  Read-only view of a sprite agent's conversation history for one project —
  the turns it took, the tools it called and what they returned, with
  sub-agent turns attributed to the sub-agent via `agent_role`. New turns
  stream in live while the sprite runs, with no reload and nothing the
  operator can send back.

  Deliberately separate from `InboxLive`: that is a support queue where a
  person is writing to the operator; this is a machine being watched. Agent
  conversations never appear in `Conversations.list_conversations/1` or count
  toward `Conversations.unread_count/1`, so watching a sprite never raises the
  support inbox's unread badge.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpecWeb.ChatComponents

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  # The project comes off the scope, not out of a lookup here: `PortableHost`
  # resolves `:project_id` for every route in this live_session. It attaches on
  # `handle_params`, which is why this cannot run in `mount`.
  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      project ->
        {:noreply, mount_project(socket, project)}
    end
  end

  defp mount_project(socket, project) do
    scope = with_active_project(socket.assigns.current_scope, project)
    conversation = Conversations.get_agent_conversation(scope, project.id)

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
    |> assign(:page_title, "#{project.name} · Agent conversation")
    |> assign(:recording_gap, conversation != nil and messages_for(conversation) == [])
    |> assign(:questions, questions_for(conversation))
    |> stream(:messages, messages_for(conversation), reset: true)
  end

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

  defp questions_for(nil), do: []

  defp questions_for(conversation),
    do: Notifications.list_question_requests_for_session(conversation.session_external_id)

  defp messages_for(nil), do: []
  defp messages_for(conversation), do: Conversations.list_messages(conversation)

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
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
          <.icon name="hero-cpu-chip" class="size-5" />
          <h1 class="truncate text-lg font-semibold">{@project.name} · Agent conversation</h1>
        </header>

        <div class="min-h-0 flex-1 overflow-y-auto py-4">
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

          <div id="agent-turns" phx-update="stream" class="space-y-3">
            <ChatComponents.turn
              :for={{dom_id, message} <- @streams.messages}
              id={dom_id}
              message={message}
              tool_role={:call}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
