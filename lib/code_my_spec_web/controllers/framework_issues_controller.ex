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
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project

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

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Invalid deploy key"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required parameter: issue"})
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
