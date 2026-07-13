defmodule CodeMySpecWeb.WidgetUsersController do
  @moduledoc """
  Deploy-key-authenticated external-user upsert for the widget API.

  Desktop apps have no backend for CodeMySpec to pull a user list from (the
  `ProjectUsers` / `GET /api/cms/users` integration), so they push instead:
  upserting their end-user here gives chat and issue reporting a durable
  identity on the server. The Bearer credential is the project's deploy key,
  self-identifying via its blind-index hash (same flow as `WidgetSocket` and
  `FrameworkIssuesController`) — the key alone resolves the project. The
  surface is deliberately narrow: upsert only, always onto the key's project.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.ExternalUsers
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project

  action_fallback CodeMySpecWeb.FallbackController

  def upsert(conn, %{"user" => user_params}) do
    case authenticate(conn) do
      {:ok, %Project{} = project} ->
        with {:ok, external_user} <-
               ExternalUsers.upsert_external_user(project.account_id, project.id, user_params) do
          render(conn, :show, external_user: external_user)
        end

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Invalid deploy key"})
    end
  end

  def upsert(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required parameter: user"})
  end

  defp authenticate(conn) do
    with ["Bearer " <> key] <- get_req_header(conn, "authorization"),
         %Project{} = project <- Projects.get_project_by_deploy_key(key) do
      {:ok, project}
    else
      _ -> {:error, :unauthorized}
    end
  end
end
