defmodule CodeMySpecWeb.WidgetIssuesController do
  @moduledoc """
  Issue intake from an end user of a generated app.

  The deploy key in the Authorization header identifies the project. The person
  reporting is **not** authenticated and is not asked to be: someone who hits a
  bug in a shipped app has no CodeMySpec account, and requiring one means the
  report never arrives.

  The widget previously filed through `/api/issues`, which takes an OAuth token,
  so a generated project could accept no feedback until its owner had generated
  client credentials. Two QA drills reported the widget rendering correctly and
  failing only on submit — a failure shaped to look like success.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.{Issues, Projects}
  alias CodeMySpec.Projects.Project

  def create(conn, %{"issue" => issue_params}) do
    case authenticate(conn) do
      {:ok, %Project{} = project} ->
        case Issues.report_widget_issue(project.account_id, project.id, issue_params) do
          {:ok, issue} ->
            conn
            |> put_status(:created)
            |> put_view(json: CodeMySpecWeb.IssuesJSON)
            |> render(:show, issue: issue)

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", errors: changeset_errors(changeset)})
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

  # The key authenticates the *app*, never the reporter.
  defp authenticate(conn) do
    with ["Bearer " <> key] <- get_req_header(conn, "authorization"),
         %Project{} = project <- Projects.get_project_by_deploy_key(key) do
      {:ok, project}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn _changeset, _field, {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
