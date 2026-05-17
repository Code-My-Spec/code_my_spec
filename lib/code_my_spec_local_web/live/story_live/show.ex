defmodule CodeMySpecLocalWeb.StoryLive.Show do
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Projects
  alias CodeMySpec.Qa
  alias CodeMySpec.Stories
  alias CodeMySpec.Tags
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.QaHistoryComponent

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:stories}
      page_title={Map.get(assigns, :page_title, "Story")}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @story && @project}>
        <.header>
          Story {@story.id}
          <:subtitle>This is a story record from your local database.</:subtitle>
          <:actions>
            <.button navigate={~p"/projects/#{@slug}/stories"}>
              <.icon name="hero-arrow-left" />
            </.button>
            <.button navigate={~p"/projects/#{@slug}/stories/#{@story.id}/three-amigos"}>
              <.icon name="hero-squares-2x2" /> Three Amigos
            </.button>
            <.button navigate={~p"/projects/#{@slug}/stories/#{@story.id}/gherkin"}>
              <.icon name="hero-document-text" /> View Gherkin
            </.button>
            <.button navigate={~p"/projects/#{@slug}/stories/#{@story.id}/edit?return_to=show"}>
              <.icon name="hero-pencil-square" /> Edit story
            </.button>
          </:actions>
        </.header>

        <.list>
          <:item title="Title">{@story.title}</:item>
          <:item title="Description">{@story.description}</:item>
          <:item title="Acceptance criteria">
            <div :if={Enum.empty?(@story.criteria)} class="text-base-content/60 italic">
              No criteria defined
            </div>
            <ul :if={!Enum.empty?(@story.criteria)} class="space-y-2">
              <li :for={criterion <- @story.criteria} class="flex items-center gap-3">
                <button
                  phx-click="toggle_verified"
                  phx-value-id={criterion.id}
                  class={[
                    "flex items-center gap-2 px-2 py-1 rounded transition-colors",
                    criterion.verified && "bg-success/10 text-success",
                    !criterion.verified && "bg-base-200 text-base-content/60 hover:bg-base-300"
                  ]}
                >
                  <.icon
                    name={if criterion.verified, do: "hero-lock-closed", else: "hero-lock-open"}
                    class="size-4"
                  />
                </button>
                <span class={[criterion.verified && "font-medium"]}>{criterion.description}</span>
                <span
                  :if={criterion.verified && criterion.verified_at}
                  class="text-xs text-base-content/50"
                >
                  (locked {Calendar.strftime(criterion.verified_at, "%b %d, %Y")})
                </span>
              </li>
            </ul>
          </:item>
          <:item title="Tags">
            <div class="flex flex-wrap gap-2 items-center">
              <span :for={tag <- @tags} class="badge badge-primary gap-1">
                {tag.name}
                <button
                  type="button"
                  phx-click="remove_tag"
                  phx-value-tag={tag.name}
                  class="hover:text-error"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </span>
              <form phx-submit="add_tag" class="flex items-center gap-1">
                <input
                  type="text"
                  name="tag"
                  placeholder="Add tag..."
                  class="input input-xs input-bordered w-32"
                />
                <button type="submit" class="btn btn-xs btn-ghost">
                  <.icon name="hero-plus" class="size-3" />
                </button>
              </form>
            </div>
          </:item>
          <:item title="Status">{@story.status}</:item>
          <:item title="Locked at">{@story.locked_at}</:item>
          <:item title="Lock expires at">{@story.lock_expires_at}</:item>
        </.list>

        <QaHistoryComponent.qa_history
          attempts={@qa_attempts}
          invalidating_attempt_id={@invalidating_attempt_id}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    projects = Projects.list_local_projects()
    current_user = load_current_user(session)

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       slug: nil,
       story: nil,
       tags: [],
       qa_attempts: [],
       invalidating_attempt_id: nil,
       current_user: current_user,
       error: nil,
       page_title: "Story",
       subscribed?: false
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name, "id" => id}, _uri, socket) do
    with {:ok, project, scope} <- load_project_and_scope(name),
         %Stories.Story{} = story <- Stories.get_story(scope, id) do
      tags = Tags.list_story_tags(scope, story)
      qa_attempts = Qa.list_qa_attempts(scope, story.id)

      socket =
        socket
        |> assign(
          project: project,
          scope: scope,
          slug: project_slug(project),
          story: story,
          tags: tags,
          qa_attempts: qa_attempts,
          invalidating_attempt_id: nil,
          error: nil,
          page_title: "Story #{story.id}"
        )
        |> maybe_subscribe(scope)

      {:noreply, socket}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
      nil -> {:noreply, assign(socket, error: "Story not found.")}
    end
  end

  defp maybe_subscribe(%{assigns: %{subscribed?: true}} = socket, _scope), do: socket

  defp maybe_subscribe(socket, scope) do
    if connected?(socket) do
      Stories.subscribe_stories(scope)
      AcceptanceCriteria.subscribe_criteria(scope)
      assign(socket, subscribed?: true)
    else
      socket
    end
  end

  @impl true
  def handle_event("add_tag", %{"tag" => tag_name}, socket) do
    tag_name = String.trim(tag_name)
    scope = socket.assigns.scope
    story = socket.assigns.story

    if tag_name == "" do
      {:noreply, socket}
    else
      _ = Tags.add_tag(scope, story, tag_name)
      tags = Tags.list_story_tags(scope, story)
      {:noreply, assign(socket, :tags, tags)}
    end
  end

  @impl true
  def handle_event("remove_tag", %{"tag" => tag_name}, socket) do
    scope = socket.assigns.scope
    story = socket.assigns.story

    case Tags.remove_tag(scope, story, tag_name) do
      :ok ->
        tags = Tags.list_story_tags(scope, story)
        {:noreply, assign(socket, :tags, tags)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_verified", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    criterion = AcceptanceCriteria.get_criterion!(scope, id)

    result =
      if criterion.verified do
        AcceptanceCriteria.mark_unverified(scope, criterion)
      else
        AcceptanceCriteria.mark_verified(scope, criterion)
      end

    case result do
      {:ok, _criterion} ->
        story = Stories.get_story!(scope, socket.assigns.story.id)
        {:noreply, assign(socket, :story, story)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update criterion")}
    end
  end

  @impl true
  def handle_event("start_invalidate", %{"attempt_id" => attempt_id}, socket) do
    {:noreply, assign(socket, :invalidating_attempt_id, attempt_id)}
  end

  @impl true
  def handle_event("cancel_invalidate", _params, socket) do
    {:noreply, assign(socket, :invalidating_attempt_id, nil)}
  end

  @impl true
  def handle_event(
        "invalidate_qa_attempt",
        %{"attempt_id" => attempt_id, "reason" => reason},
        socket
      ) do
    scope = build_invalidation_scope(socket)
    story = socket.assigns.story

    case Qa.invalidate_qa_attempt(scope, attempt_id, reason) do
      {:ok, _invalidation} ->
        qa_attempts = Qa.list_qa_attempts(socket.assigns.scope, story.id)

        {:noreply,
         socket
         |> assign(:qa_attempts, qa_attempts)
         |> assign(:invalidating_attempt_id, nil)}

      {:error, reason_msg} ->
        {:noreply, put_flash(socket, :error, "Invalidation failed: #{inspect(reason_msg)}")}
    end
  end

  @impl true
  def handle_info(
        {:updated, %CodeMySpec.Stories.Story{id: id} = story},
        %{assigns: %{story: %{id: id}}} = socket
      ) do
    {:noreply, assign(socket, :story, story)}
  end

  def handle_info(
        {:deleted, %CodeMySpec.Stories.Story{id: id}},
        %{assigns: %{story: %{id: id}, slug: slug}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "The current story was deleted.")
     |> push_navigate(to: ~p"/projects/#{slug}/stories")}
  end

  def handle_info({type, %CodeMySpec.Stories.Story{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end

  def handle_info(
        {_type, %CodeMySpec.AcceptanceCriteria.Criterion{story_id: story_id}},
        %{assigns: %{story: %{id: story_id}}} = socket
      ) do
    story = Stories.get_story!(socket.assigns.scope, story_id)
    {:noreply, assign(socket, :story, story)}
  end

  def handle_info({_type, %CodeMySpec.AcceptanceCriteria.Criterion{}}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Build a scope for invalidation that uses the authenticated user (if any),
  # falling back to the project scope's user. This ensures the FK constraint
  # on `invalidated_by_user_id` is satisfied when accessed from the browser.
  defp build_invalidation_scope(socket) do
    base_scope = socket.assigns.scope

    case socket.assigns.current_user do
      nil -> base_scope
      user -> %{base_scope | user: user, user_id: user.id}
    end
  end

  defp load_current_user(session) do
    with token when is_binary(token) <- session["user_token"],
         {user, _token} when not is_nil(user) <- Users.get_user_by_session_token(token) do
      user
    else
      _ -> nil
    end
  end

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
