defmodule CodeMySpecWeb.ProjectController do
  @moduledoc """
  API controller for project information.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Projects

  @doc """
  GET /api/projects
  Returns the list of projects for the authenticated user.
  """
  def index(conn, _params) do
    scope = conn.assigns.current_scope
    projects = Projects.list_projects(scope)

    json(conn, %{
      projects: Enum.map(projects, &project_json/1)
    })
  end

  defp project_json(project) do
    %{
      id: project.id,
      account_id: project.account_id,
      name: project.name,
      description: project.description,
      module_name: project.module_name,
      code_repo: project.code_repo,
      docs_repo: project.docs_repo,
      client_api_url: project.client_api_url,
      status: project.status
    }
  end
end
