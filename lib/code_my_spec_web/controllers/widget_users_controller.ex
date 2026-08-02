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
  alias CodeMySpec.Projects.Project
  alias CodeMySpecWeb.AppCredential

  action_fallback CodeMySpecWeb.FallbackController

  def upsert(conn, %{"user" => user_params}) do
    case authenticate(conn) do
      {:ok, %Project{} = project} ->
        with {:ok, external_user} <-
               ExternalUsers.upsert_external_user(project.account_id, project.id, user_params) do
          render(conn, :show, external_user: external_user)
        end

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, _} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Invalid deploy key"})
    end
  end

  # Auth before the missing-parameter complaint (8045).
  def upsert(conn, _params) do
    case authenticate(conn) do
      {:ok, %Project{}} ->
        param_error(conn)

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, _} ->
        conn |> put_status(:unauthorized) |> json(%{status: "error", error: "Unauthorized"})
    end
  end

  defp param_error(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required parameter: user"})
  end

  # Either credential names the project: a short-lived access token from
  # `POST /api/token`, or the durable deploy key. Token first, key second —
  # that ordering is the migration, since dropping the key here would break
  # every deployed caller the moment this shipped.
  defp authenticate(conn) do
    # `:expired` is preserved rather than folded into `:unauthorized` — a
    # client holding an aged-out token should renew and retry, and one holding
    # a wrong credential should stop. Criterion 8023.
    AppCredential.project(conn)
  end
end
