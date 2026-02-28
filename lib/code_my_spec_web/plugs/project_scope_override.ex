defmodule CodeMySpecWeb.Plugs.ProjectScopeOverride do
  @moduledoc """
  Overrides the active project in scope when an `X-Project-ID` header is present.

  Runs after authentication (require_oauth_token) and checks for the header.
  If present, loads the project, verifies the user has account access, and
  overrides the scope. If absent, passes through unchanged for backward
  compatibility.
  """

  import Plug.Conn
  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    scope = conn.assigns[:current_scope]

    case {scope, get_req_header(conn, "x-project-id")} do
      {nil, _} ->
        conn

      {_scope, []} ->
        conn

      {_scope, [""]} ->
        conn

      {scope, [project_id | _]} ->
        override_project(conn, scope, project_id)
    end
  end

  defp override_project(conn, scope, project_id) do
    case Repo.get(Project, project_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.json(%{error: "Project not found"})
        |> halt()

      %Project{} = project ->
        if Accounts.user_has_account_access?(scope, project.account_id) do
          account = Repo.get(CodeMySpec.Accounts.Account, project.account_id)

          updated_scope = %{
            scope
            | active_project: project,
              active_project_id: project.id,
              active_account: account,
              active_account_id: project.account_id
          }

          assign(conn, :current_scope, updated_scope)
        else
          conn
          |> put_status(:forbidden)
          |> Phoenix.Controller.json(%{error: "Access denied to project"})
          |> halt()
        end
    end
  end
end
