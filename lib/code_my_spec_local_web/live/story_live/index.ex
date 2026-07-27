defmodule CodeMySpecLocalWeb.StoryLive.Index do
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Markdown
  alias CodeMySpec.Users.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:stories}
      page_title={Map.get(assigns, :page_title, "Stories")}
    >
      <div :if={@project} role="tablist" class="tabs tabs-bordered mb-6">
        <.link
          navigate={~p"/projects/#{@slug}/stories"}
          role="tab"
          class={["tab", "tab-active"]}
        >
          Stories
        </.link>
        <.link
          navigate={~p"/projects/#{@slug}/stories/scheduler"}
          role="tab"
          class="tab"
        >
          Scheduler
        </.link>
      </div>

      <.header>
        Stories
        <:actions>
          <div :if={@project} class="flex items-center gap-3">
            <label class="flex items-center gap-2 cursor-pointer">
              <span class="text-sm text-base-content/70">Criteria</span>
              <input
                type="checkbox"
                class="toggle toggle-sm toggle-primary"
                checked={@show_criteria}
                phx-click="toggle_criteria"
              />
            </label>
            <div class="divider divider-horizontal mx-0"></div>
            <button phx-click="export_markdown" class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-down-tray" /> Export
            </button>
            <.button navigate={~p"/projects/#{@slug}/stories/import"} class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-up-tray" /> Import
            </.button>
            <.button navigate={~p"/projects/#{@slug}/stories/new"} class="btn btn-sm">
              <.icon name="hero-plus" /> New Story
            </.button>
          </div>
        </:actions>
      </.header>

      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project} id="stories" phx-update="stream" class="space-y-8">
        <div :for={{id, story} <- @streams.stories} id={id} class="card bg-base-100 shadow-md">
          <div class="card-body">
            <div class="flex items-start justify-between mb-4">
              <h2
                class="card-title text-2xl cursor-pointer hover:text-primary flex-1"
                phx-click={JS.navigate(~p"/projects/#{@slug}/stories/#{story.id}")}
              >
                {story.title}
              </h2>
              <div class="flex items-center gap-2">
                <span
                  :if={story.ready_for_dev == true}
                  data-test="story-ready"
                  class="badge badge-success"
                >
                  Ready for development
                </span>
                <span
                  :if={story.ready_for_dev != true}
                  data-test="story-not-ready"
                  class="badge badge-ghost"
                >
                  Parked
                </span>
                <button
                  type="button"
                  phx-click="toggle_story_ready"
                  phx-value-id={story.id}
                  data-test="toggle-story-ready"
                  class="btn btn-ghost btn-xs"
                >
                  {if story.ready_for_dev == true, do: "Park", else: "Release"}
                </button>
                <div
                  :if={is_nil(story.component_id)}
                  class="alert alert-warning py-1 px-3 flex items-center gap-2"
                >
                  <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
                  <span class="text-sm">No Component</span>
                </div>
              </div>
            </div>

            <p class="text-base-content/80 mb-4 leading-relaxed">
              {story.story || story.description}
            </p>

            <p :if={story.notes not in [nil, ""]} class="text-sm text-base-content/60 mb-4 italic">
              Notes: {story.notes}
            </p>

            <div :if={@show_criteria} class="mb-4">
              <h3 class="font-semibold mb-2">Acceptance Criteria:</h3>
              <ul class="list-disc list-inside space-y-1 text-base-content/80">
                <li :for={criterion <- story.criteria} class="flex items-center gap-2">
                  <.icon
                    :if={criterion.verified}
                    name="hero-lock-closed"
                    class="size-3 text-success inline"
                  />
                  <span class={[criterion.verified && "font-medium"]}>{criterion.description}</span>
                </li>
              </ul>
              <div
                :if={
                  Enum.empty?(story.criteria) &&
                    !Enum.empty?(parse_acceptance_criteria(story.acceptance_criteria))
                }
                class="text-xs text-base-content/50 mt-1"
              >
                (legacy criteria: {length(parse_acceptance_criteria(story.acceptance_criteria))})
              </div>
            </div>

            <div :if={story.component_id} class="mb-4">
              <div class="text-sm text-base-content/60">
                <span class="font-semibold">Component:</span>
                <span class="font-mono text-xs">{String.slice(story.component_id, 0, 8)}...</span>
              </div>
            </div>

            <div :if={story.tags != []} class="mb-4 flex flex-wrap gap-1">
              <span :for={tag <- story.tags} class="badge badge-sm badge-outline">
                {tag.name}
              </span>
            </div>

            <div class="flex items-center justify-between">
              <div class="card-actions">
                <.link
                  navigate={~p"/projects/#{@slug}/stories/#{story.id}/three-amigos"}
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-squares-2x2" class="size-4" /> Three Amigos
                </.link>
                <.link
                  navigate={~p"/projects/#{@slug}/stories/#{story.id}/gherkin"}
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-document-text" class="size-4" /> Gherkin
                </.link>
                <.link navigate={~p"/projects/#{@slug}/stories/#{story.id}/edit"} class="btn btn-sm btn-outline">
                  Edit
                </.link>
                <button
                  type="button"
                  phx-click={show_confirm("confirm-delete-story-#{story.id}")}
                  class="btn btn-sm btn-error btn-outline"
                >
                  Delete
                </button>
                <.confirm_dialog
                  id={"confirm-delete-story-#{story.id}"}
                  title={"Delete story \"#{story.title}\"?"}
                  message="This removes the story and its rules/scenarios; linked issues are preserved with story_id cleared."
                  confirm_label="Delete"
                  on_confirm={JS.push("delete", value: %{id: story.id}) |> hide("##{id}")}
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     socket
     |> assign(
       projects: projects,
       project: nil,
       scope: nil,
       slug: nil,
       error: nil,
       show_criteria: true,
       page_title: "Stories",
       subscribed?: false
     )
     |> stream(:stories, [])}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        socket =
          socket
          |> assign(project: project, scope: scope, slug: project_slug(project), error: nil)
          |> maybe_subscribe(scope)
          |> stream(:stories, Stories.list_project_stories_by_priority(scope), reset: true)

        {:noreply, socket}

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  defp maybe_subscribe(%{assigns: %{subscribed?: true}} = socket, _scope), do: socket

  defp maybe_subscribe(socket, scope) do
    if connected?(socket) do
      Stories.subscribe_stories(scope)
      assign(socket, subscribed?: true)
    else
      socket
    end
  end

  @impl true
  def handle_event("toggle_criteria", _params, socket) do
    new_show = !socket.assigns.show_criteria

    {:noreply,
     socket
     |> assign(:show_criteria, new_show)
     |> stream(
       :stories,
       Stories.list_project_stories_by_priority(socket.assigns.scope),
       reset: true
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    story = Stories.get_story!(scope, id)
    {:ok, _} = Stories.delete_story(scope, story)

    {:noreply, stream_delete(socket, :stories, story)}
  end

  @impl true
  def handle_event("toggle_story_ready", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    story = Stories.get_story!(scope, id)

    case Stories.update_story(scope, story, %{ready_for_dev: !(story.ready_for_dev == true)}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :stories, updated)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change readiness: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("export_markdown", _params, socket) do
    scope = socket.assigns.scope
    {:ok, stories} = Stories.list_project_stories(scope)
    project_name = scope.active_project.name

    story_attrs =
      stories
      |> Enum.sort_by(& &1.title)
      |> Enum.map(&story_to_attrs/1)

    markdown_content = Markdown.format_stories(story_attrs, project_name)
    filename = "#{String.downcase(String.replace(project_name, " ", "_"))}_stories.md"

    {:noreply,
     push_event(socket, "download_file", %{
       content: markdown_content,
       filename: filename,
       content_type: "text/markdown"
     })}
  end

  @impl true
  def handle_info({type, %CodeMySpec.Stories.Story{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(
       socket,
       :stories,
       Stories.list_project_stories_by_priority(socket.assigns.scope),
       reset: true
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  defp parse_acceptance_criteria(nil), do: []
  defp parse_acceptance_criteria(""), do: []
  defp parse_acceptance_criteria(criteria) when is_list(criteria), do: criteria

  defp parse_acceptance_criteria(criteria) when is_binary(criteria) do
    criteria
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp story_to_attrs(story) do
    criteria_list =
      if Enum.empty?(story.criteria) do
        parse_acceptance_criteria(story.acceptance_criteria)
      else
        Enum.map(story.criteria, & &1.description)
      end

    %{
      title: story.title,
      description: story.description,
      acceptance_criteria: criteria_list
    }
  end
end
