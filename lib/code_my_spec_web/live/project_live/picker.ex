defmodule CodeMySpecWeb.ProjectLive.Picker do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.UserPreferences

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
  def handle_event("project-selected", %{"project-id" => project_id}, socket) do
    current_scope = socket.assigns.current_scope

    # Validate that the user has access to this project
    if Enum.any?(socket.assigns.projects, &(&1.id == project_id)) do
      case UserPreferences.update_user_preferences(current_scope, %{active_project_id: project_id}) do
        {:ok, _user_preference} ->
          {:noreply,
           socket
           |> put_flash(:info, "Project selected successfully")
           |> push_navigate(to: ~p"/app")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to select project")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have access to this project")}
    end
  end

  # Helper function to format dates
  defp format_date(date) do
    Calendar.strftime(date, "%B %d, %Y")
  end
end
