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

  alias CodeMySpec.Agents
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

  # The project's own agent, and its conversation, or why there is not one.
  #
  # The conversation is fetched here rather than in the template because a main
  # agent with no conversation is a state the page must not render a link for —
  # it would go to a transcript that does not exist.
  defp ensure_main(scope) do
    with {:ok, agent} <- Agents.ensure_main_agent(scope),
         {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             scope.active_account_id,
             scope.active_project_id,
             agent.id
           ) do
      {:ok, agent, conversation}
    end
  end

  defp main_agent_id({:ok, agent, _conversation}), do: agent.id
  defp main_agent_id(_), do: nil

  # Which checkout it is in. On the page rather than inferred from elsewhere,
  # because "the agent runs in the copy you designated" is a claim a reader
  # should be able to check without going and looking somewhere else.
  defp main_copy_id({:ok, agent, _conversation}), do: agent.working_copy_id
  defp main_copy_id(_), do: nil

  defp main_path(project, {:ok, _agent, conversation}),
    do: ~p"/app/projects/#{project.id}/agent-conversation/#{conversation.id}"

  defp main_path(project, _), do: ~p"/app/projects/#{project.id}/agent-conversation"

  # Two sentences about where the project is, in the words somebody who does not
  # read code would use. A placeholder for now, and deliberately not a status
  # line assembled from row counts — the agent is what will write this, and a
  # summary built out of numbers here would have to be unbuilt when it does.
  defp main_summary({:ok, agent, _conversation}) do
    case agent.status do
      :running -> "Working on your project. Open the conversation to see what it is doing."
      _ -> "Getting ready. It will start work as soon as its machine picks it up."
    end
  end

  defp main_summary(_), do: ""

  # The line under the name, and the one thing on the row that tells two agents
  # apart when their generated names do not.
  #
  # It was `session_external_id`, which read `pi:<path>` and so carried the
  # checkout by accident. Keying a conversation on its agent emptied that column
  # for every agent thread, and the line went blank — the page lost exactly the
  # fact that distinguishes three copies of one project, which is the complaint
  # (18f50c87) that put the path into the key in the first place.
  #
  # Now it says which checkout, and the role when there is one, because "qa" and
  # "main" on the same copy is the case story 1023 is about. A Claude Code lane
  # has no agent row and keeps its external id.
  defp row_subtitle(%{working_copy: copy, role: role}) when is_binary(copy) do
    case role do
      nil -> copy
      role -> "#{copy} · #{role}"
    end
  end

  defp row_subtitle(%{conversation: %{session_external_id: id}}) when is_binary(id), do: id

  defp row_subtitle(_row), do: ""

  defp load(socket, project) do
    scope = %{
      socket.assigns.current_scope
      | active_project: project,
        active_project_id: project.id
    }

    socket
    |> assign(:main, ensure_main(scope))
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

        <%!-- The one thing to talk to, above the list of everything that has
        ever recorded a turn. Those are different questions and answering the
        second where the first was asked is how a non-technical user ends up
        choosing a checkout. --%>
        <div
          :if={match?({:ok, _, _}, @main)}
          data-test="main-agent"
          data-agent-id={main_agent_id(@main)}
          data-working-copy-id={main_copy_id(@main)}
          class="mt-6 rounded-box border border-primary/40 bg-primary/5 p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <div>
              <div class="font-semibold">Your project's agent</div>
              <div data-test="project-summary" class="text-sm opacity-70">
                {main_summary(@main)}
              </div>
            </div>
            <.button navigate={main_path(@project, @main)} class="btn btn-sm btn-primary">
              Open
            </.button>
          </div>
        </div>

        <%!-- Two failures, two remedies, and telling them apart is the whole
        value of saying anything. Nowhere to run is `mix cms.new` or designating
        a checkout you already have; nothing to run on is connecting a provider.
        A single "unavailable" would send half of the people who read it to the
        wrong place. --%>
        <p
          :if={match?({:error, :no_main_working_copy}, @main)}
          data-test="no-main-working-copy"
          class="mt-6 rounded-box border border-warning/40 bg-warning/10 p-4 text-sm"
        >
          This project has no main working copy yet, so there is nowhere for its
          agent to run. Run <code>mix cms.new</code> to make one, or open a
          checkout you already have and make it the main copy.
        </p>

        <p
          :if={match?({:error, :not_connected}, @main)}
          data-test="no-provider"
          class="mt-6 rounded-box border border-warning/40 bg-warning/10 p-4 text-sm"
        >
          This project has a main working copy but no provider connected, so its
          agent has nothing to run on. Connect one and it will come up.
        </p>

        <p
          :if={@rows == []}
          data-test="agent-conversations-empty"
          class="py-16 text-center opacity-60"
        >
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
                    {row_subtitle(row)}
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
