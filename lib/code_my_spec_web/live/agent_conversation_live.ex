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
  alias CodeMySpec.Projects

  @impl true
  def mount(%{"project_name" => project_name}, _session, socket) do
    case Projects.get_project_by_name(socket.assigns.current_scope, project_name) do
      {:ok, project} ->
        {:ok, mount_project(socket, project)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}
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
    |> stream(:messages, messages_for(conversation))
  end

  # `active_project_id` is what `Conversations.get_agent_conversation/2` scopes
  # on, so both fields are set together — otherwise the page for one project
  # could read another project's turns off a stale `active_project_id`.
  defp with_active_project(scope, project),
    do: %{scope | active_project: project, active_project_id: project.id}

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

          <div id="agent-turns" phx-update="stream" class="space-y-3">
            <.turn :for={{dom_id, message} <- @streams.messages} id={dom_id} message={message} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :message, :any, required: true

  # Blank-body turns (an assistant message with nothing but tool calls) render
  # as nothing rather than an empty bubble — a tool-only turn must never look
  # like it produced no evidence.
  defp turn(%{message: %{body: ""}} = assigns) do
    ~H"""
    <div id={@id} class="hidden"></div>
    """
  end

  defp turn(%{message: %{role: :tool}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-test="tool-call"
      data-agent-role={@message.agent_role}
      class="rounded-box bg-base-200 p-3"
    >
      <div :if={@message.agent_role} class="mb-1 text-xs uppercase opacity-60">
        {@message.agent_role}
      </div>
      <pre class="whitespace-pre-wrap break-words font-mono text-sm">{@message.body}</pre>
    </div>
    """
  end

  defp turn(assigns) do
    ~H"""
    <div
      id={@id}
      data-test="message"
      data-role={@message.role}
      data-agent-role={@message.agent_role}
      class={["chat", chat_side(@message.role)]}
    >
      <div :if={@message.agent_role} class="chat-header text-xs opacity-60">
        {@message.agent_role}
      </div>
      <div class={["chat-bubble whitespace-pre-wrap break-words", chat_bubble(@message.role)]}>
        {@message.body}
      </div>
    </div>
    """
  end

  defp chat_side(:assistant), do: "chat-end"
  defp chat_side(_role), do: "chat-start"

  defp chat_bubble(:assistant), do: "chat-bubble-primary"
  defp chat_bubble(_role), do: "bg-base-200 text-base-content"
end
