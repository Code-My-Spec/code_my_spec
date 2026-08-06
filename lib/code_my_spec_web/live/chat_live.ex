defmodule CodeMySpecWeb.ChatLive do
  @moduledoc """
  Two-way chat with an agent, and where the first story gets shaped.

  Someone lands here after signup. The agent asks, they answer, and the calls
  it makes are shown as it makes them — a conversation that goes quiet while
  something happens off-screen reads as broken, which is the same reason the
  intake interview fills the workspace boot instead of showing a bar.

  The story the agent creates is rendered through the real story form, not a
  chat-local copy of one. A second editing surface drifts, and the one that
  drifts is the one nobody is looking at.

  Distinct from `IntakeLive`, which is everything before signup, and from
  `AgentConversationLive`, which watches a sprite with nothing to send back.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Chat.Runner
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Stories

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, section: :chat)}

  # The project comes off the scope — `PortableHost` resolves `:project_id` for
  # every route in this live_session and attaches on handle_params, which is
  # why this cannot run in mount.
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
    scope = socket.assigns.scope

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id || project.account_id,
        project.id,
        "story-interview:#{project.id}"
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        CodeMySpec.PubSub,
        Conversations.conversation_topic(conversation.id)
      )
    end

    socket
    |> assign(:project, project)
    |> assign(:conversation, conversation)
    |> assign(:page_title, "#{project.name} — Chat")
    |> assign(:thinking?, false)
    |> assign(:editing?, false)
    |> assign_story(scope)
    |> stream(:messages, Conversations.list_messages(conversation), reset: true)
  end

  # The story under discussion, if the conversation has made one yet. Read from
  # the project rather than tracked in assigns so an edit made anywhere shows
  # up here on the next render.
  defp assign_story(socket, scope) do
    story =
      case Stories.list_project_stories(scope) do
        {:ok, [story | _]} -> story
        _ -> nil
      end

    socket
    |> assign(:story, story)
    |> assign(:story_form, story && to_form(Stories.change_story(scope, story, %{})))
  end

  @impl true
  def handle_event("send", %{"message" => text}, socket) when text != "" do
    conversation = socket.assigns.conversation

    :ok = Runner.run(conversation, text)

    {:noreply,
     socket
     |> assign(:thinking?, false)
     |> assign_story(socket.assigns.scope)
     |> stream(:messages, Conversations.list_messages(conversation), reset: true)}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("save_story", %{"story" => params}, socket) do
    scope = socket.assigns.scope

    case Stories.update_story(scope, socket.assigns.story, params) do
      {:ok, _story} -> {:noreply, assign_story(socket, scope)}
      {:error, changeset} -> {:noreply, assign(socket, :story_form, to_form(changeset))}
    end
  end

  # Idempotent: opening an already-open card is not an error, and the card is
  # the affordance that says the story can be changed.
  def handle_event("open_story", _params, socket), do: {:noreply, assign(socket, :editing?, true)}

  def handle_event("start_three_amigos", _params, socket) do
    {:noreply, assign(socket, :three_amigos_started?, true)}
  end

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
        data-test="chat"
        data-project-id={@project.id}
        style="height: calc(100dvh - 7rem)"
        class="mx-auto flex w-full max-w-3xl flex-col"
      >
        <div class="min-h-0 flex-1 overflow-y-auto py-4">
          <div id="chat-turns" phx-update="stream" class="space-y-3">
            <.turn :for={{dom_id, message} <- @streams.messages} id={dom_id} message={message} />
          </div>

          <div :if={@thinking?} data-test="chat-thinking" class="py-2 opacity-60">Working…</div>

          <.story_card :if={@story} story={@story} form={@story_form} editing?={@editing?} />
        </div>

        <form data-test="chat-compose" phx-submit="send" class="flex shrink-0 gap-2 pt-3">
          <input name="message" class="input input-bordered flex-1" placeholder="Answer…" />
          <.button type="submit">Send</.button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :story, :any, required: true
  attr :form, :any, required: true
  attr :editing?, :boolean, required: true

  # The real story form, rendered inline. Editing here and editing on the
  # stories page are the same act on the same record.
  defp story_card(assigns) do
    ~H"""
    <section
      data-test="story-card"
      phx-click="open_story"
      class="rounded-box border border-base-300 p-4"
    >
      <h3 :if={!@editing?} class="font-semibold">{@story.title}</h3>

      <.form
        :if={@editing?}
        for={@form}
        data-test="story-form"
        phx-submit="save_story"
        class="mt-3 space-y-2"
      >
        <.input field={@form[:title]} label="Title" />
        <.input field={@form[:description]} type="textarea" label="Story" />
        <.button type="submit">Save</.button>
      </.form>

      <.button data-test="start-three-amigos" phx-click="start_three_amigos" class="btn-ghost mt-3">
        Start Three Amigos
      </.button>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :message, :any, required: true

  # A halted or failed conversation is a turn you can see, not a flag only the
  # server knows about.
  # A model that would not stop and a provider that fell over are different
  # events, and reading the same is how one gets mistaken for the other.
  defp turn(%{message: %{agent_role: role}} = assigns) when role in ["halted", "failed"] do
    assigns = assign(assigns, :marker, "chat-#{role}")

    ~H"""
    <div
      id={@id}
      data-test={@marker}
      class="rounded-box border border-warning/40 bg-warning/10 p-3 text-sm"
    >
      {Message.text(@message)}
    </div>
    """
  end

  defp turn(%{message: %{role: :assistant, tool_calls: calls}} = assigns) when is_list(calls) do
    ~H"""
    <div id={@id} class="space-y-2">
      <div
        :for={call <- @message.tool_calls}
        data-test="tool-call"
        data-tool={call["name"]}
        data-tool-call-id={call["id"]}
        data-state="done"
        class="rounded-box bg-base-200 p-3 font-mono text-xs"
      >
        {call["name"]}
      </div>
    </div>
    """
  end

  defp turn(%{message: %{role: :tool}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-test="tool-result"
      data-tool-call-id={@message.tool_call_id}
      class="rounded-box bg-base-200 p-3"
    >
      <pre class="whitespace-pre-wrap break-words font-mono text-xs">{Message.text(@message)}</pre>
    </div>
    """
  end

  defp turn(assigns) do
    ~H"""
    <div
      id={@id}
      data-test="message"
      data-role={@message.role}
      class={["chat", chat_side(@message.role)]}
    >
      <div class={["chat-bubble whitespace-pre-wrap break-words", chat_bubble(@message.role)]}>
        {Message.text(@message)}
      </div>
    </div>
    """
  end

  defp chat_side(:assistant), do: "chat-end"
  defp chat_side(_role), do: "chat-start"

  defp chat_bubble(:assistant), do: "chat-bubble-primary"
  defp chat_bubble(_role), do: "bg-base-200 text-base-content"
end
