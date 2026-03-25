defmodule CodeMySpecLocalWeb.IssuesController do
  @moduledoc """
  Read-only API for issues. Mutations are handled via MCP tools.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Issues
  alias CodeMySpecLocalWeb.IssuesMarkdown

  def index(conn, %{"project_name" => project_name} = params) do
    scope = conn.assigns.current_scope
    filters = parse_filters(params)
    issues = Issues.list_filtered(scope, filters)

    markdown =
      IssuesMarkdown.index(issues,
        base_path: "/api/projects/#{project_name}",
        filters: filters
      )

    text(conn, markdown)
  end

  def show(conn, %{"id" => id, "project_name" => project_name}) do
    scope = conn.assigns.current_scope

    case Issues.get_issue(scope, id) do
      nil ->
        conn |> put_status(404) |> text("Issue not found: #{id}")

      issue ->
        text(conn, IssuesMarkdown.show(issue, base_path: "/api/projects/#{project_name}"))
    end
  end

  defp parse_filters(params) do
    %{}
    |> maybe_put(:status, parse_atom(params["status"]))
    |> maybe_put(:severity, parse_atom(params["severity"]))
    |> maybe_put(:scope, parse_atom(params["scope"]))
    |> maybe_put(:story_id, params["story_id"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_atom(nil), do: nil
  defp parse_atom(s) when is_binary(s) and s != "", do: String.to_existing_atom(s)
  defp parse_atom(_), do: nil
end
