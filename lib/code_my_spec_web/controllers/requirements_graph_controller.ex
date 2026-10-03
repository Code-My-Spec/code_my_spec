defmodule CodeMySpecWeb.RequirementsGraphController do
  @moduledoc """
  A project's cached requirement graph, over the cloud API.

  The same payload the local app's `/api/projects/:project_name/requirements/graph`
  serves — both render `CodeMySpec.Requirements.GraphReport` — for a caller that
  holds a credential rather than a seat on the machine: a harness with its
  project's deploy key, or a user's OAuth token.

  Addressed by id rather than name: a name is unique per local install, not
  across accounts.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.GraphReport

  def show(conn, %{"project_id" => project_id} = params) do
    case authorize(conn, project_id) do
      {:ok, scope} ->
        json(conn, GraphReport.read(scope, params))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "No project #{project_id}"})

      {:error, :forbidden} ->
        conn
        |> put_status(403)
        |> json(%{error: "This credential does not reach project #{project_id}"})
    end
  end

  defp authorize(conn, project_id) do
    scope = conn.assigns.current_scope

    with {:ok, project} <- fetch_project(project_id),
         :ok <- reaches(conn.assigns[:deploy_key_project_id], scope, project) do
      {:ok, pin(scope, project)}
    end
  end

  defp fetch_project(project_id) do
    case Projects.get_project_by_id(project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  # A deploy key reaches its own project and no other, whatever its account
  # owner can see.
  defp reaches(nil, scope, project) do
    if Accounts.user_has_account_access?(scope, project.account_id),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp reaches(key_project_id, _scope, project) do
    if to_string(key_project_id) == to_string(project.id), do: :ok, else: {:error, :forbidden}
  end

  # A working copy adopted from `X-Harness-Id` belongs to the scope's own
  # project; reading another project keeps none of it.
  defp pin(scope, project) do
    copy_id = if scope.active_project_id == project.id, do: scope.active_working_copy_id

    %{
      scope
      | active_project: project,
        active_project_id: project.id,
        active_account_id: project.account_id,
        active_working_copy_id: copy_id
    }
  end
end
