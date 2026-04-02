defmodule CodeMySpecWeb.IssuesController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Issues

  action_fallback CodeMySpecWeb.FallbackController

  def index(conn, params) do
    scope = conn.assigns.current_scope
    filters = build_filters(params)
    issues = Issues.list_filtered(scope, filters)
    render(conn, :index, issues: issues)
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Issues.get_issue(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Issue not found"})

      issue ->
        render(conn, :show, issue: issue)
    end
  end

  def create(conn, %{"issue" => issue_params}) do
    scope = conn.assigns.current_scope

    with {:ok, issue} <- Issues.create_issue(scope, issue_params) do
      conn
      |> put_status(:created)
      |> render(:show, issue: issue)
    end
  end

  defp build_filters(params) do
    %{}
    |> maybe_put(:status, atomize(params["status"]))
    |> maybe_put(:severity, atomize(params["severity"]))
    |> maybe_put(:scope, atomize(params["scope"]))
    |> maybe_put(:source, atomize(params["source"]))
    |> maybe_put(:story_id, params["story_id"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp atomize(nil), do: nil
  defp atomize(s) when is_binary(s), do: String.to_existing_atom(s)
end
