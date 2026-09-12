defmodule CodeMySpecWeb.AgentConversationLive.Index do
  @moduledoc """
  Every agent session recorded against a project, newest activity first.

  Exists because `Show` used to answer "whichever conversation moved most
  recently". With one agent that reads as *the* conversation; with five it hides
  four, and which one you land on changes as they take turns.

  ## What a row has to carry

  A name, and something underneath it that tells two rows apart. Five sessions
  on one project are usually five checkouts of the same repository, so the
  session's own name is the only thing separating them until somebody sets one —
  which is why `Conversations` generates a name at creation rather than leaving
  this page to render five UUIDs.

  The checkout and the role come from the agent row. A Claude Code lane has an
  external id and no agent, so it has neither and the line is left off rather
  than rendered empty.

  ## Renaming here rather than on its own route

  `WorkingCopyLive.Index` sends renaming to `WorkingCopyLive.Form`, on the
  grounds that a list with an edit box on every row buries what you came to
  read. That holds for a checkout, whose name is a convenience over a path that
  already identifies it. It does not hold here: a generated name is the *only*
  handle, the useful one is "backend refactor", and only the person reading this
  list knows which session that is. Sending them somewhere else to say so is
  where the naming stops happening.

  So the box is one row at a time, opened by a control and closed by saving or
  cancelling — what the sibling is guarding against is a page of live inputs and
  a stray return key, not the existence of a rename.

  ## Where a row goes

  Into the cockpit, as `?conversation=<id>`. Switching sessions there is a patch
  rather than a navigation, so this page hands over a selection rather than
  opening a different page — and a reader who arrived from here can switch again
  without coming back.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Conversations
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent sessions")
     |> assign(:renaming, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    handle_project(socket.assigns[:project], socket)
  end

  defp handle_project(nil, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "That project is not yours, or does not exist.")
     |> push_navigate(to: ~p"/app/projects")}
  end

  defp handle_project(_project, socket) do
    follow(connected?(socket), socket.assigns.current_scope)
    {:noreply, load(socket)}
  end

  # Every agent turn broadcasts on the account's inbox topic, and that is the
  # moment the ordering this page claims — newest activity first — stops being
  # true. Listening is read-only: an agent conversation still never appears in
  # the support inbox's list or its unread count.
  defp follow(true, scope) do
    Phoenix.PubSub.subscribe(
      CodeMySpec.PubSub,
      Conversations.inbox_topic(scope.active_account_id)
    )
  end

  defp follow(false, _scope), do: :ok

  @impl true
  def handle_info({:inbox_updated, _conversation_id}, socket) do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("rename", %{"id" => id}, socket) do
    {:noreply, assign(socket, :renaming, id)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :renaming, nil)}
  end

  # Which row is being renamed is `@renaming`, not a hidden field. The form is
  # only rendered for that one row, so a submitted id could only ever agree with
  # it or be wrong — and the assign is the copy the scope check will be made
  # against either way.
  def handle_event("save_rename", %{"name" => name}, socket) do
    socket.assigns.current_scope
    |> Conversations.rename_agent_conversation(socket.assigns.renaming, name)
    |> renamed(socket)
  end

  defp renamed({:ok, _conversation}, socket) do
    {:noreply,
     socket
     |> assign(:renaming, nil)
     |> load()}
  end

  defp renamed({:error, :not_found}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "That session is not yours, or no longer exists.")
     |> assign(:renaming, nil)
     |> load()}
  end

  # The name is the only thing a person sets here, so a refusal says what was
  # wrong with it. A flash reading "could not save" over a list still showing
  # the generated name is the page declining without saying why, and the row
  # stays open so the text they typed is still there to fix.
  defp renamed({:error, changeset}, socket) do
    {:noreply, put_flash(socket, :error, "Name #{name_error(changeset)}.")}
  end

  defp name_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.get(:name, ["could not be saved"])
    |> Enum.join(", ")
  end

  defp load(socket) do
    rows =
      Conversations.list_agent_conversations(
        socket.assigns.current_scope,
        socket.assigns.project.id
      )

    assign(socket, rows: rows, now: DateTime.utc_now())
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
      <div data-test="agent-conversations" class="mx-auto w-full max-w-3xl">
        <.header>
          Agent sessions
          <:subtitle>
            Every agent that has worked this project, most recent first. Open one to read
            what it did, or rename it so you can tell it from the others.
          </:subtitle>
        </.header>

        <p
          :if={@rows == []}
          data-test="agent-conversations-empty"
          class="py-16 text-center opacity-60"
        >
          No sessions yet. One appears the first time an agent takes a turn on this project.
        </p>

        <ul class="mt-6 space-y-3">
          <li
            :for={row <- @rows}
            data-test="agent-conversation"
            data-conversation-id={row.conversation.id}
            class="card card-compact border border-base-300 bg-base-100"
          >
            <div class="card-body gap-2">
              <div class="flex items-start gap-3">
                <.icon name="hero-cpu-chip" class="mt-0.5 size-5 shrink-0 opacity-60" />

                <div class="min-w-0 flex-1">
                  <.link
                    :if={@renaming != row.conversation.id}
                    navigate={
                      ~p"/app/projects/#{@project.id}/agent-conversation?#{[conversation: row.conversation.id]}"
                    }
                    data-test="open-agent-conversation"
                    class="block min-w-0 truncate font-medium link link-hover"
                  >
                    {Conversations.display_name(row.conversation)}
                  </.link>

                  <form
                    :if={@renaming == row.conversation.id}
                    phx-submit="save_rename"
                    data-test="rename-agent-conversation"
                    class="flex items-center gap-2"
                  >
                    <.input
                      name="name"
                      value={Conversations.display_name(row.conversation)}
                      class="input input-sm w-full"
                      autocomplete="off"
                      maxlength="80"
                    />
                    <.button type="submit" class="btn-sm">Save</.button>
                    <button type="button" phx-click="cancel_rename" class="btn btn-sm btn-ghost">
                      Cancel
                    </button>
                  </form>

                  <%!-- The checkout, because five sessions on one project are
                  usually five copies of the same repository and the name is the
                  only other thing separating them. A Claude Code lane has no
                  agent row, so it has neither and the line is left off. --%>
                  <p
                    :if={row.working_copy}
                    data-test="agent-conversation-copy"
                    class="min-w-0 truncate text-xs opacity-60"
                  >
                    <span :if={row.role}>{row.role} · </span>{row.working_copy}
                  </p>
                </div>

                <div class="shrink-0 text-right text-xs opacity-60">
                  <p data-test="agent-conversation-turns">{turns(row.message_count)}</p>
                  <p :if={row.last_message_at} data-test="agent-conversation-last">
                    {Liveness.since(row.last_message_at, @now)}
                  </p>
                </div>
              </div>

              <button
                :if={@renaming != row.conversation.id}
                type="button"
                phx-click="rename"
                phx-value-id={row.conversation.id}
                data-test="rename-agent-conversation-start"
                class="-ml-2 flex items-center gap-1 self-start text-xs opacity-50 hover:opacity-100"
              >
                <.icon name="hero-pencil-square" class="size-4" /> Rename
              </button>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  defp turns(1), do: "1 turn"
  defp turns(count), do: "#{count} turns"
end
