defmodule CodeMySpecWeb.FrameworkIssuesController do
  @moduledoc """
  Deploy-key-authenticated framework issue intake.

  For clients with no OAuth session — widget-style embeds and other external
  reporters. The Bearer credential is the CodeMySpec project's deploy key:
  self-identifying via its blind-index hash (same flow as `WidgetSocket`), so
  the key alone resolves the project and no project id crosses the wire. The
  surface is deliberately narrow — create only, scope forced to `framework`
  by `Issues.report_framework_issue/3`.

  Installed CLIs do NOT use this endpoint: they file framework issues over
  their OAuth session via POST /api/issues, with `ProjectScopeOverride`
  allowing that one write against the configured CodeMySpec project.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Issues
  alias CodeMySpec.Projects.Project
  alias CodeMySpecWeb.AppCredential

  action_fallback CodeMySpecWeb.FallbackController

  def create(conn, %{"issue" => issue_params}) do
    case authenticate(conn) do
      {:ok, %Project{} = project} ->
        with {:ok, issue} <-
               Issues.report_framework_issue(project.account_id, project.id, issue_params) do
          conn
          |> put_status(:created)
          |> put_view(json: CodeMySpecWeb.IssuesJSON)
          |> render(:show, issue: issue)
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

  # Auth before the missing-parameter complaint: an unauthenticated caller
  # must not learn this endpoint's contract by sending it garbage (8045).
  def create(conn, _params) do
    case authenticate(conn) do
      {:ok, %Project{}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", error: "Missing required parameter: issue"})

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, _} ->
        conn |> put_status(:unauthorized) |> json(%{status: "error", error: "Unauthorized"})
    end
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
