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

  alias CodeMySpec.Issues
  alias CodeMySpec.Projects.Project
  alias CodeMySpecWeb.AppCredential

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

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Access token expired", reason: "expired"})

      {:error, _} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", error: "Unauthorized"})
    end
  end

  # Auth before the missing-parameter complaint, matching the users controller
  # (8045). An unauthenticated caller learning the parameter shape is a small
  # leak on its own; the larger cost was that a wrong-credential request got a
  # 400 that reads like it authenticated fine, which is how the credential
  # defect in this controller went unnoticed through a QA pass.
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

  # Either credential names the app: the short-lived access token a deployed
  # app exchanges its refresh secret for, or the durable deploy key. Never the
  # reporter — someone hitting a bug in a shipped product has no CodeMySpec
  # account and should not need one to say so.
  #
  # Previously deploy-key only, which left an app holding just the short-lived
  # credential able to register a visitor at /api/widget/users and unable to
  # file that visitor's feedback here — the users controller had been migrated
  # to AppCredential and this one had not.
  defp authenticate(conn) do
    AppCredential.project(conn)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn _changeset, _field, {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
