defmodule CodeMySpecLocalWeb.StoryLive.Scheduler do
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:scheduler}
      page_title="Story Scheduler"
    >
      <div :if={@project} role="tablist" class="tabs tabs-bordered mb-6">
        <.link
          navigate={~p"/projects/#{@slug}/stories"}
          role="tab"
          class="tab"
        >
          Stories
        </.link>
        <.link
          navigate={~p"/projects/#{@slug}/stories/scheduler"}
          role="tab"
          class={["tab", "tab-active"]}
        >
          Scheduler
        </.link>
      </div>

      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project}>
        <.header>
          Story Scheduler
          <:subtitle>Drag and drop to prioritize stories</:subtitle>
        </.header>

        <div class="mt-8">
          <ul
            id="scheduler-list"
            phx-hook=".StoryScheduler"
            phx-update="stream"
            class="space-y-3 min-h-[200px]"
          >
            <li
              :for={{id, story} <- @streams.stories}
              id={id}
              data-story-id={story.id}
              class="card bg-base-100 shadow-md cursor-move hover:shadow-lg transition-all duration-200 hover:-translate-y-1 select-none"
            >
              <div class="card-body py-4">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-4 flex-1">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-bars-3" class="w-5 h-5 text-base-content/40" />
                      <span class="font-mono text-sm text-base-content/60 min-w-[3ch]">
                        {story.priority || "—"}
                      </span>
                    </div>

                    <div class="flex-1">
                      <h3 class="font-semibold text-lg">{story.title}</h3>
                      <p class="text-sm text-base-content/60 line-clamp-1">
                        {story.description}
                      </p>
                    </div>
                  </div>

                  <div class="flex items-center gap-4">
                    <div :if={is_nil(story.component_id)} class="badge badge-warning badge-sm">
                      No Component
                    </div>
                    <div
                      :if={story.component_id}
                      class="badge badge-outline badge-sm font-mono text-xs"
                    >
                      {String.slice(story.component_id, 0, 8)}...
                    </div>
                    <div class="text-right text-sm text-base-content/60">
                      <div>Criteria: {length(story.criteria)}</div>
                    </div>
                  </div>
                </div>
              </div>
            </li>
          </ul>

          <div :if={@story_count == 0} class="text-center py-16">
            <.icon name="hero-document-text" class="w-16 h-16 mx-auto text-base-content/20 mb-4" />
            <h3 class="text-lg font-semibold mb-2">No Stories Yet</h3>
            <p class="text-base-content/60 mb-4">Create your first story to start scheduling.</p>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".StoryScheduler">
          export default {
            mounted() {
              new window.Sortable(this.el, {
                animation: 150,
                ghostClass: "opacity-50",
                dragClass: "shadow-2xl",
                chosenClass: "ring-2",

                onEnd: (evt) => {
                  const storyIds = Array.from(this.el.children).map(item =>
                    item.dataset.storyId
                  )

                  this.pushEvent("reorder_priorities", {
                    story_ids: storyIds
                  })
                }
              })
            }
          }
        </script>
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
       page_title: "Story Scheduler",
       story_count: 0,
       subscribed?: false
     )
     |> stream(:stories, [])}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        stories = Stories.list_project_stories_by_priority(scope)

        socket =
          socket
          |> assign(
            project: project,
            scope: scope,
            slug: project_slug(project),
            error: nil,
            story_count: length(stories)
          )
          |> maybe_subscribe(scope)
          |> stream(:stories, stories, reset: true)

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
  def handle_event("reorder_priorities", %{"story_ids" => story_ids}, socket) do
    scope = socket.assigns.scope

    story_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {story_id, new_priority} ->
      case Stories.get_story(scope, story_id) do
        %Story{} = story -> Stories.update_story(scope, story, %{priority: new_priority})
        nil -> :ok
      end
    end)

    stories = Stories.list_project_stories_by_priority(scope)

    {:noreply,
     socket
     |> assign(:story_count, length(stories))
     |> stream(:stories, stories, reset: true)}
  end

  @impl true
  def handle_info({type, %Story{}}, socket) when type in [:created, :updated, :deleted] do
    stories = Stories.list_project_stories_by_priority(socket.assigns.scope)

    {:noreply,
     socket
     |> assign(:story_count, length(stories))
     |> stream(:stories, stories, reset: true)}
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
end
