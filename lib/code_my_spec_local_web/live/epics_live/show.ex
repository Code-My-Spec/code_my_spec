defmodule CodeMySpecLocalWeb.EpicsLive.Show do
  @moduledoc """
  A single epic and the stories it contains, with per-story readiness toggles
  and a one-shot bulk release.

  The bulk release stamps the stories that are in the epic *at that moment*.
  Stories added later stay parked — the epic holds no readiness of its own.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Epics
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       projects: Projects.list_local_projects(),
       project: nil,
       scope: nil,
       slug: nil,
       error: nil,
       page_title: "Epic",
       epic: nil
     )}
  end

  @impl true
  def handle_params(%{"slug" => epic_slug} = params, _url, socket) do
    with {:ok, project, scope} <- load_project_and_scope(params["project_name"]),
         epic when not is_nil(epic) <- Epics.get_epic_by_slug(scope, epic_slug) do
      {:noreply,
       socket
       |> assign(
         project: project,
         scope: scope,
         slug: project_slug(project),
         error: nil,
         page_title: epic.name,
         epic: epic
       )}
    else
      nil ->
        {:noreply, assign(socket, error: "Epic not found")}

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  @impl true
  def handle_event("bulk_release", _params, socket) do
    scope = socket.assigns.scope
    epic = socket.assigns.epic

    case Epics.set_epic_stories_ready(scope, epic, true) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{count} #{noun(count)} released for development. Stories added later stay parked."
         )
         |> reload_epic()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not release: #{inspect(reason)}")}
    end
  end

  def handle_event("bulk_park", _params, socket) do
    scope = socket.assigns.scope
    epic = socket.assigns.epic

    case Epics.set_epic_stories_ready(scope, epic, false) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{noun(count)} parked.")
         |> reload_epic()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not park: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_story_ready", %{"id" => id}, socket) do
    scope = socket.assigns.scope

    case Stories.get_story(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Story not found")}

      story ->
        case Stories.update_story(scope, story, %{ready_for_dev: !(story.ready_for_dev == true)}) do
          {:ok, _story} -> {:noreply, reload_epic(socket)}
          {:error, reason} -> {:noreply, put_flash(socket, :error, "#{inspect(reason)}")}
        end
    end
  end

  defp reload_epic(socket) do
    assign(socket, :epic, Epics.get_epic_by_slug(socket.assigns.scope, socket.assigns.epic.slug))
  end

  defp noun(1), do: "story"
  defp noun(_), do: "stories"

  defp epic_stories(epic) do
    if epic && Ecto.assoc_loaded?(epic.stories), do: epic.stories, else: []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:epics}
      page_title={@page_title}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @epic}>
        <.header>
          {@epic.name}
          <:subtitle>{@epic.description}</:subtitle>
          <:actions>
            <.link navigate={~p"/app/projects/#{@slug}/epics"} class="btn btn-ghost btn-sm">
              Back to epics
            </.link>
            <button
              type="button"
              phx-click="bulk_release"
              data-test="bulk-release-epic"
              class="btn btn-primary btn-sm"
            >
              Release these stories for development
            </button>
            <button type="button" phx-click="bulk_park" data-test="bulk-park-epic" class="btn btn-ghost btn-sm">
              Park them
            </button>
          </:actions>
        </.header>

        <p class="mt-2 text-sm opacity-70">
          Releasing stamps the {length(epic_stories(@epic))} stories in this epic right now.
          Stories added afterwards stay parked.
        </p>

        <div :if={epic_stories(@epic) == []} class="mt-8 card bg-base-200" data-test="empty-state">
          <div class="card-body">
            <h2 class="card-title">No stories in this epic</h2>
            <p>Move stories in from the epics list.</p>
          </div>
        </div>

        <ul :if={epic_stories(@epic) != []} class="mt-8 space-y-2">
          <li
            :for={story <- epic_stories(@epic)}
            class="card bg-base-100 border border-base-300"
            data-test={"epic-story-#{story.id}"}
          >
            <div class="card-body py-3 flex-row items-center justify-between gap-4">
              <div>
                <h3 class="font-semibold">{story.title}</h3>
                <p class="text-sm opacity-70">{story.story || story.description}</p>
              </div>

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
                  data-test={"toggle-epic-story-#{story.id}"}
                  class="btn btn-ghost btn-xs"
                >
                  {if story.ready_for_dev == true, do: "Park", else: "Release"}
                </button>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
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
