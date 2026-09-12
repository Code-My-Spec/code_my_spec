defmodule CodeMySpecWeb.StoryLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Components
  alias CodeMySpec.Qa
  alias CodeMySpec.Stories
  alias CodeMySpec.Tags
  alias CodeMySpecWeb.StoryLive.QaHistoryComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error || @scope_error} role="alert" class="alert alert-error">
      <span>{@error || @scope_error}</span>
    </div>

    <div :if={!@error && @story && @project}>
      <.header>
        <%!--
        The number, not the id. A story carries both, and the number is what
        names its spex directory — story id 1031 is number 1065, and its specs
        live in `test/spex/1065_…/`. They coincide on a young project and
        diverge later, which is how "Story 1031" stayed on this page for months
        while naming a directory that does not exist (1ab62ffd).
        --%>
        Story {@story.number}
        <:subtitle>Story detail, acceptance criteria, tags, and QA history.</:subtitle>
        <:actions>
          <.button navigate={path(@socket, ~p"/app/projects/#{@slug}/stories")}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button navigate={
            path(@socket, ~p"/app/projects/#{@slug}/stories/#{@story.id}/three-amigos")
          }>
            <.icon name="hero-squares-2x2" /> Three Amigos
          </.button>
          <.button navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/#{@story.id}/gherkin")}>
            <.icon name="hero-document-text" /> View Gherkin
          </.button>
          <.button navigate={
            path(@socket, ~p"/app/projects/#{@slug}/stories/#{@story.id}/edit?return_to=show")
          }>
            <.icon name="hero-pencil-square" /> Edit story
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Title">{@story.title}</:item>
        <:item title="Description">{@story.description}</:item>
        <:item title="Component">
          <div :if={@component} class="flex items-center gap-2 flex-wrap">
            <span class="badge badge-secondary font-mono">{@component.module_name}</span>
            <span class="badge badge-ghost badge-sm">{@component.type}</span>
          </div>
          <div
            :if={!@component && @story.component_id}
            role="alert"
            class="alert alert-warning alert-soft text-sm"
          >
            <.icon name="hero-exclamation-triangle" class="size-4" />
            <span>
              Linked to a missing component (<span class="font-mono">{String.slice(@story.component_id, 0, 8)}…</span>) — dangling reference; re-link this story to a real component.
            </span>
          </div>
          <div :if={!@component && !@story.component_id} class="text-base-content/60 italic">
            Not linked to a component.
          </div>
        </:item>
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
        <:item title="Locked at">{@story.locked_at}</:item>
        <:item title="Lock expires at">{@story.lock_expires_at}</:item>
      </.list>

      <QaHistoryComponent.qa_history
        attempts={@qa_attempts}
        invalidating_attempt_id={@invalidating_attempt_id}
      />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :stories,
       project: nil,
       scope: nil,
       slug: nil,
       story: nil,
       component: nil,
       tags: [],
       qa_attempts: [],
       invalidating_attempt_id: nil,
       error: nil,
       page_title: "Story",
       subscribed?: false
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{scope: %{} = scope}} = socket) do
    case Stories.get_story(scope, id) do
      %Stories.Story{} = story ->
        tags = Tags.list_story_tags(scope, story)
        qa_attempts = Qa.list_qa_attempts(scope, story.id)
        component = story.component_id && Components.get_component(scope, story.component_id)

        socket =
          socket
          |> assign(
            story: story,
            component: component,
            tags: tags,
            qa_attempts: qa_attempts,
            invalidating_attempt_id: nil,
            error: nil,
            page_title: "Story #{story.number}"
          )
          |> maybe_subscribe(scope)

        {:noreply, socket}

      nil ->
        {:noreply, assign(socket, error: "Story not found.")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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
     |> push_navigate(to: path(socket, ~p"/app/projects/#{slug}/stories"))}
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

  # Attribute the invalidation to the signed-in user rather than to whoever
  # the project scope happens to carry, so the `invalidated_by_user_id` FK
  # records the person who actually clicked the button.
  defp build_invalidation_scope(socket) do
    base_scope = socket.assigns.scope

    case socket.assigns.current_scope do
      %{user: %{} = user} -> %{base_scope | user: user, user_id: user.id}
      _ -> base_scope
    end
  end
end
