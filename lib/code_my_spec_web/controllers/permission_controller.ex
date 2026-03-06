defmodule CodeMySpecWeb.PermissionController do
  @moduledoc """
  API controller for permission requests from Claude Code.

  Protected by OAuth — the local server authenticates via its stored token.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Notifications

  @doc """
  POST /api/permissions/request

  Create a permission request and send Web Push notification.
  """
  def create(conn, %{"tool_name" => tool_name} = params) do
    scope = conn.assigns.current_scope
    tool_input = Map.get(params, "tool_input", %{})

    case Notifications.create_permission_request(scope.user.id, %{
           "tool_name" => tool_name,
           "tool_input" => tool_input
         }) do
      {:ok, request} ->
        conn |> put_status(:created) |> json(%{id: request.id})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required field: tool_name"})
  end

  @doc """
  POST /api/permissions/:id/respond

  Respond to a permission request with a decision.
  """
  def respond(conn, %{"id" => id, "decision" => decision})
      when decision in ~w(allow deny) do
    scope = conn.assigns.current_scope

    case Notifications.get_permission_request(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})

      %{user_id: user_id} when user_id != scope.user.id ->
        conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})

      %{status: "pending"} ->
        case Notifications.resolve_permission_request(id, decision) do
          {:ok, _} -> json(conn, %{status: "ok"})
          {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
        end

      %{status: status} ->
        conn |> put_status(:conflict) |> json(%{error: "Already resolved: #{status}"})
    end
  end

  def respond(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required fields: id, decision (allow or deny)"})
  end

  @doc """
  GET /api/permissions/:id/status

  Returns the current status of a permission request.
  Used by the local server to poll for resolution.
  """
  def status(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Notifications.get_permission_request(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})

      %{user_id: user_id} when user_id != scope.user.id ->
        conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})

      request ->
        json(conn, %{
          id: request.id,
          status: request.status,
          decision: request.decision,
          tool_name: request.tool_name
        })
    end
  end
end
