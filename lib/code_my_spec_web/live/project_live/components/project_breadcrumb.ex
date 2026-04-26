defmodule CodeMySpecWeb.ProjectLive.Components.ProjectBreadcrumb do
  use CodeMySpecWeb, :html

  @doc """
  Renders a projects breadcrumb component.

  Shows the current project name with a link to switch projects.
  Displays "Select Project" if no project is currently selected.

  ## Example

      <.projects_breadcrumb scope={@scope} />

  """
  attr :scope, :map, required: true, doc: "Current user scope with active project"
  attr :current_path, :string, default: "/"

  def project_breadcrumb(assigns) do
    assigns = assign_new(assigns, :current_project, fn -> resolve_current_project(assigns.scope) end)

    ~H"""
    <div class="breadcrumbs text-sm">
      <ul>
        <li>
          <.link navigate={~p"/app/projects/picker?return_to=#{@current_path}"}>
            <%= if @current_project do %>
              {@current_project.name}
            <% else %>
              Select Project
            <% end %>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp resolve_current_project(%{active_project_id: nil}), do: nil

  defp resolve_current_project(%{active_project_id: project_id} = scope) do
    case CodeMySpec.Projects.get_project(scope, project_id) do
      {:ok, project} -> project
      {:error, :not_found} -> nil
    end
  end
end
