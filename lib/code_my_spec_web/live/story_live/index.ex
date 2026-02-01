defmodule CodeMySpecWeb.StoryLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Markdown

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Listing Stories
        <:actions>
          <div class="flex items-center gap-3">
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
            <.button navigate={~p"/app/stories/import"} class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-up-tray" /> Import
            </.button>
            <.button navigate={~p"/app/stories/new"} class="btn btn-sm">
              <.icon name="hero-plus" /> New Story
            </.button>
          </div>
        </:actions>
      </.header>

      <div id="stories" phx-update="stream" class="space-y-8">
        <div :for={{id, story} <- @streams.stories} id={id} class="card bg-base-100 shadow-md">
          <div class="card-body">
            <div class="flex items-start justify-between mb-4">
              <h2
                class="card-title text-2xl cursor-pointer hover:text-primary flex-1"
                phx-click={JS.navigate(~p"/app/stories/#{story}")}
              >
                {story.title}
              </h2>
              <div
                :if={is_nil(story.component_id)}
                class="alert alert-warning py-1 px-3 flex items-center gap-2"
              >
                <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
                <span class="text-sm">No Component</span>
              </div>
            </div>

            <p class="text-base-content/80 mb-4 leading-relaxed">
              {story.description}
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
                <.link navigate={~p"/app/stories/#{story}/edit"} class="btn btn-sm btn-outline">
                  Edit
                </.link>
                <.link
                  phx-click={JS.push("delete", value: %{id: story.id}) |> hide("##{id}")}
                  data-confirm="Are you sure?"
                  class="btn btn-sm btn-error btn-outline"
                >
                  Delete
                </.link>
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
    if connected?(socket) do
      Stories.subscribe_stories(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Stories")
     |> assign(:show_criteria, true)
     |> stream(
       :stories,
       Stories.list_project_stories_by_priority(socket.assigns.current_scope)
     )}
  end

  @impl true
  def handle_event("toggle_criteria", _params, socket) do
    new_show = !socket.assigns.show_criteria

    {:noreply,
     socket
     |> assign(:show_criteria, new_show)
     |> stream(
       :stories,
       Stories.list_project_stories_by_priority(socket.assigns.current_scope),
       reset: true
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    story = Stories.get_story!(socket.assigns.current_scope, id)
    {:ok, _} = Stories.delete_story(socket.assigns.current_scope, story)

    {:noreply, stream_delete(socket, :stories, story)}
  end

  @impl true
  def handle_event("export_markdown", _params, socket) do
    {:ok, stories} = Stories.list_project_stories(socket.assigns.current_scope)
    project_name = socket.assigns.current_scope.active_project.name

    story_attrs =
      stories
      |> Enum.sort_by(& &1.title)
      |> Enum.map(&story_to_attrs/1)

    markdown_content = Markdown.format_stories(story_attrs, project_name)
    filename = "#{String.downcase(String.replace(project_name, " ", "_"))}_stories.md"

    {:noreply,
     socket
     |> push_event("download_file", %{
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
       Stories.list_project_stories_by_priority(socket.assigns.current_scope),
       reset: true
     )}
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
    # Prefer criteria association, fall back to legacy acceptance_criteria field
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
