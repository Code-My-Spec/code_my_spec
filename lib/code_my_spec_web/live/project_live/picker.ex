defmodule CodeMySpecWeb.ProjectLive.Picker do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.UserPreferences
  alias CodeMySpecWeb.MainAgentConversation

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center min-h-screen px-4">
      <div class="w-full max-w-md">
        <.header>
          Select Project
          <:subtitle>Choose which project you'd like to work with</:subtitle>
        </.header>

        <div class="mt-8">
          <ul class="menu bg-base-200 rounded-box w-full">
            <li
              :for={project <- @projects}
              class={if project.id == @current_project_id, do: "bordered", else: ""}
            >
              <a
                phx-click="project-selected"
                phx-value-project-id={project.id}
                class={if project.id == @current_project_id, do: "active", else: ""}
              >
                <div class="flex-1">
                  <div class="font-semibold">{project.name}</div>
                  <div class="text-sm opacity-70 line-clamp-3">
                    {if project.description, do: project.description, else: "No description"}
                  </div>
                  <div class="text-xs opacity-50">
                    Updated {format_date(project.updated_at)}
                  </div>
                </div>
                <div :if={project.id == @current_project_id} class="badge badge-primary">
                  Current
                </div>
              </a>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    current_scope = socket.assigns.current_scope
    projects = Projects.list_projects(current_scope)
    current_project_id = current_scope.active_project_id
    return_to = params["return_to"] || "/"

    {:ok,
     socket
     |> assign(:projects, projects)
     |> assign(:current_project_id, current_project_id)
     |> assign(:return_to, return_to)}
  end

  @impl true
  # Picking a project is navigation now. The path is what selects it — every
  # page reads its project out of the URL — so this sends you there rather than
  # storing a selection and hoping the next page agrees.
  #
  # The preference is still written, demoted to a bookmark: all it decides is
  # where bare `/app` drops you next time. A failed write is not worth blocking
  # the navigation the user actually asked for, so it is not checked.
  def handle_event("project-selected", %{"project-id" => project_id}, socket) do
    case Enum.find(socket.assigns.projects, &(&1.id == project_id)) do
      %{} = project ->
        UserPreferences.update_user_preferences(socket.assigns.current_scope, %{
          active_project_id: project_id
        })

        path = MainAgentConversation.path(socket.assigns.current_scope, project)
        {:noreply, push_navigate(socket, to: path)}

      nil ->
        {:noreply, put_flash(socket, :error, "You don't have access to this project")}
    end
  end

  # Helper function to format dates
  defp format_date(date) do
    Calendar.strftime(date, "%B %d, %Y")
  end
end
