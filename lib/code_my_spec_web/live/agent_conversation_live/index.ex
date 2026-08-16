defmodule CodeMySpecWeb.AgentConversationLive.Index do
  @moduledoc """
  Every agent session recorded against a project, newest activity first.

  This page exists because the transcript page used to answer "whichever
  conversation moved most recently". With one agent that reads as *the*
  conversation; with five it hides four, and which one you land on changes as
  they take turns.

  A session is named so it can be told apart. The name is generated when the
  conversation is created — an index of five UUIDs is the problem this page
  exists to solve, and it would have appeared before anyone had the chance to
  name anything — and editable here, because the useful name is "backend
  refactor" and only a person knows that.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Conversations

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :renaming, nil)}

  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      project ->
        {:noreply, load(socket, project)}
    end
  end

  defp load(socket, project) do
    scope = %{
      socket.assigns.current_scope
      | active_project: project,
        active_project_id: project.id
    }

    socket
    |> assign(:current_scope, scope)
    |> assign(:project, project)
    |> assign(:page_title, "#{project.name} · Agents")
    |> assign(:rows, Conversations.list_agent_conversations(scope, project.id))
  end

  @impl true
  def handle_event("rename", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :renaming, id)}

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, :renaming, nil)}

  def handle_event("save_name", %{"_id" => id, "name" => name}, socket) do
    case Conversations.rename_conversation(socket.assigns.current_scope, id, name) do
      {:ok, _conversation} ->
        {:noreply,
         socket
         |> assign(:renaming, nil)
         |> load(socket.assigns.project)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That conversation is not yours.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That name could not be saved.")}
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
      <div data-test="agent-conversations" class="mx-auto w-full max-w-3xl">
        <.header>
          Agents
          <:subtitle>Every session that has recorded work on {@project.name}</:subtitle>
        </.header>

        <p :if={@rows == []} data-test="agent-conversations-empty" class="py-16 text-center opacity-60">
          <.icon name="hero-cpu-chip" class="mx-auto mb-3 size-10" />
          No agent has recorded a turn on this project yet.
        </p>

        <ul class="mt-6 space-y-2">
          <li
            :for={row <- @rows}
            data-test="agent-conversation-row"
            data-id={row.conversation.id}
            data-session={row.conversation.session_external_id}
          >
            <div class="card card-compact border border-base-300 bg-base-100">
              <div class="card-body flex-row items-center gap-3">
                <.icon name="hero-cpu-chip" class="size-5 shrink-0 opacity-60" />

                <form
                  :if={@renaming == row.conversation.id}
                  phx-submit="save_name"
                  class="flex min-w-0 flex-1 items-center gap-2"
                >
                  <%!-- `_id`, not `id`: a form input named `id` overrides the
                        form element's own DOM id, which LiveView needs. --%>
                  <input type="hidden" name="_id" value={row.conversation.id} />
                  <input
                    type="text"
                    name="name"
                    value={row.conversation.name}
                    autofocus
                    placeholder="name this agent"
                    class="input input-sm input-bordered min-w-0 flex-1"
                  />
                  <button type="submit" class="btn btn-sm btn-primary shrink-0">Save</button>
                  <button
                    type="button"
                    phx-click="cancel_rename"
                    class="btn btn-sm btn-ghost shrink-0"
                  >
                    Cancel
                  </button>
                </form>

                <.link
                  :if={@renaming != row.conversation.id}
                  navigate={
                    ~p"/app/projects/#{@project.id}/agent-conversation/#{row.conversation.id}"
                  }
                  class="min-w-0 flex-1"
                >
                  <p class="truncate font-medium">
                    {Conversations.display_name(row.conversation)}
                  </p>
                  <p class="truncate font-mono text-xs opacity-50">
                    {row.conversation.session_external_id}
                  </p>
                </.link>

                <div
                  :if={@renaming != row.conversation.id}
                  class="flex shrink-0 flex-col items-end gap-1"
                >
                  <span class="text-xs opacity-60">{row.message_count} turns</span>
                  <time :if={row.last_message_at} class="text-xs opacity-40">
                    {Calendar.strftime(row.last_message_at, "%b %-d, %H:%M")}
                  </time>
                </div>

                <button
                  :if={@renaming != row.conversation.id}
                  phx-click="rename"
                  phx-value-id={row.conversation.id}
                  data-test="rename"
                  title="Rename"
                  class="btn btn-ghost btn-xs btn-square shrink-0"
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </button>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
