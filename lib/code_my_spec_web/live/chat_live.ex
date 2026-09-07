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
  alias CodeMySpec.Stories
  alias CodeMySpecWeb.ChatComponents

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

    # A story interview is not an agent in any sense — it borrowed the agent
    # thread's shape and is keyed by its own external id.
    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
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
    |> assign(:turn, nil)
    |> assign(:editing?, false)
    |> assign_story(scope)
    |> stream(:messages, Conversations.list_messages(conversation), reset: true)
  end

  # Everything the end of a turn settles, in one place so the async and inline
  # paths cannot answer differently.
  defp finish_turn(socket) do
    socket
    |> assign(:thinking?, false)
    |> assign(:turn, nil)
    |> assign_story(socket.assigns.scope)
    |> stream(:messages, Conversations.list_messages(socket.assigns.conversation), reset: true)
  end

  defp async?, do: Application.get_env(:code_my_spec, :chat_turn_async, true)

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

  # The turn runs somewhere else, and the page says so while it does.
  #
  # `Runner.run/2` is the whole server-side agent loop — up to twelve provider
  # round trips — and it used to run here, in the LiveView's own process. That
  # meant no re-render, no other event, and no progress until it finished: on
  # `/app/projects/:id/chat`, the first surface after signup, somebody typed,
  # pressed send, and watched a still page for as long as the model took.
  # "Thinking" and "broken" looked the same, and `:thinking?` — the assign that
  # exists to tell them apart — was written `false` twice and `true` nowhere.
  @impl true
  def handle_event("send", %{"message" => text}, socket) when text != "" do
    conversation = socket.assigns.conversation

    if async?() do
      # `async_nolink` rather than `start_child` and a hand-rolled message: a
      # turn that crashes must still end the wait. With a plain send at the
      # bottom of the task, a raise skips it and the page says "Working…" for
      # ever — an indicator that is wrong rather than merely absent, which is
      # worse than the freeze this replaces.
      #
      # The monitor gives both endings for free: `{ref, :ok}` when the turn
      # returns, `{:DOWN, ...}` when it dies, and both clear the indicator.
      task = Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fn ->
        Runner.run(conversation, text)
      end)

      {:noreply, socket |> assign(:thinking?, true) |> assign(:turn, task.ref)}
    else
      # Inline in test, where a task in another process cannot see the sandbox's
      # transaction. Same reasoning as `intake_shaping_async` — and the state a
      # test wants to assert is the finished turn rather than a race toward it.
      :ok = Runner.run(conversation, text)
      {:noreply, finish_turn(socket)}
    end
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

  # Opens the review on the story the card is showing.
  #
  # This set an assign nothing rendered, so the button was a dead click: no
  # navigation, no marker, no change to the DOM at all (issue `1366f527`).
  # `StoryLive.ThreeAmigos` already exists and is already routed — the button
  # simply never went there.
  #
  # `story_card/1` is the only caller and it requires a story, so there is
  # always one to review. Guarded anyway rather than matching on it: a nil here
  # would raise inside the route helper, and a dead button that crashes is
  # worse than the dead button this replaces.
  def handle_event("start_three_amigos", _params, socket) do
    case socket.assigns.story do
      nil ->
        {:noreply, socket}

      story ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/app/projects/#{story.project_id}/stories/#{story.id}/three-amigos"
         )}
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  # The turn is over, whatever it produced. `Conversations` broadcasts each
  # message as it lands, so the transcript is already current by now — what this
  # carries is the end of the wait, plus the story, which the turn may have
  # created or changed and which nothing broadcasts.
  def handle_info({ref, _result}, %{assigns: %{turn: ref}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_turn(socket)}
  end

  # The turn died. The same ending, because from the page's side it is: nobody
  # is working on this any more, and continuing to say otherwise is the one
  # outcome worse than saying nothing. What went wrong is in the transcript if
  # the runner got far enough to write it, and in the logs if it did not.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{turn: ref}} = socket) do
    {:noreply, finish_turn(socket)}
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
            <ChatComponents.turn
              :for={{dom_id, message} <- @streams.messages}
              id={dom_id}
              message={message}
            />
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
end
