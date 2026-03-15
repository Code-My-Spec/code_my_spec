defmodule CodeMySpec.LocalServer.Controllers.IssuesController do
  @moduledoc """
  Local server controller for issue management via CLI bash tools.
  """

  import Plug.Conn

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue

  def index(conn) do
    scope = conn.assigns[:current_scope]
    filters = parse_filters(conn)

    issues = Issues.list_filtered(scope, filters)

    json_response(conn, 200, %{
      issues: Enum.map(issues, &serialize/1),
      count: length(issues)
    })
  end

  def show(conn) do
    scope = conn.assigns[:current_scope]
    id = conn.path_params["id"]

    case Issues.get_issue(scope, id) do
      nil ->
        json_response(conn, 404, %{error: "Issue not found"})

      issue ->
        json_response(conn, 200, %{issue: serialize(issue)})
    end
  end

  def create(conn) do
    scope = conn.assigns[:current_scope]
    body = conn.body_params

    attrs = %{
      title: body["title"],
      severity: parse_atom(body["severity"]),
      description: body["description"],
      scope: parse_atom(body["scope"] || "app"),
      story_id: parse_integer(body["story_id"]),
      source_path: body["source_path"]
    }

    case Issues.create_issue(scope, attrs) do
      {:ok, issue} ->
        json_response(conn, 201, %{issue: serialize(issue)})

      {:error, changeset} ->
        json_response(conn, 422, %{error: format_errors(changeset)})
    end
  end

  def accept(conn) do
    scope = conn.assigns[:current_scope]
    id = conn.path_params["id"]

    with {:ok, issue} <- fetch_issue(scope, id),
         {:ok, updated} <- Issues.accept_issue(scope, issue) do
      json_response(conn, 200, %{issue: serialize(updated)})
    else
      {:error, :not_found} ->
        json_response(conn, 404, %{error: "Issue not found"})

      {:error, changeset} ->
        json_response(conn, 422, %{error: format_errors(changeset)})
    end
  end

  def dismiss(conn) do
    scope = conn.assigns[:current_scope]
    id = conn.path_params["id"]
    reason = conn.body_params["reason"]

    if is_nil(reason) or reason == "" do
      json_response(conn, 422, %{error: "Missing required field: reason"})
    else
      with {:ok, issue} <- fetch_issue(scope, id),
           {:ok, updated} <- Issues.dismiss_issue(scope, issue, reason) do
        json_response(conn, 200, %{issue: serialize(updated)})
      else
        {:error, :not_found} ->
          json_response(conn, 404, %{error: "Issue not found"})

        {:error, changeset} ->
          json_response(conn, 422, %{error: format_errors(changeset)})
      end
    end
  end

  def resolve(conn) do
    scope = conn.assigns[:current_scope]
    id = conn.path_params["id"]
    resolution = conn.body_params["resolution"]

    if is_nil(resolution) or resolution == "" do
      json_response(conn, 422, %{error: "Missing required field: resolution"})
    else
      with {:ok, issue} <- fetch_issue(scope, id),
           {:ok, updated} <- Issues.resolve_issue(scope, issue, resolution) do
        json_response(conn, 200, %{issue: serialize(updated)})
      else
        {:error, :not_found} ->
          json_response(conn, 404, %{error: "Issue not found"})

        {:error, changeset} ->
          json_response(conn, 422, %{error: format_errors(changeset)})
      end
    end
  end

  # -- Private ----------------------------------------------------------------

  defp fetch_issue(scope, id) do
    case Issues.get_issue(scope, id) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  defp parse_filters(conn) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    %{}
    |> maybe_put(:status, parse_atom(params["status"]))
    |> maybe_put(:severity, parse_atom(params["severity"]))
    |> maybe_put(:story_id, parse_integer(params["story_id"]))
    |> maybe_put(:scope, parse_atom(params["scope"]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_atom(nil), do: nil
  defp parse_atom(s) when is_binary(s) and s != "", do: String.to_existing_atom(s)
  defp parse_atom(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(i) when is_integer(i), do: i

  defp parse_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp serialize(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      severity: to_string(issue.severity),
      scope: to_string(issue.scope),
      status: to_string(issue.status),
      description: issue.description,
      resolution: issue.resolution,
      story_id: issue.story_id,
      source_path: issue.source_path,
      inserted_at: issue.inserted_at && DateTime.to_iso8601(issue.inserted_at)
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
