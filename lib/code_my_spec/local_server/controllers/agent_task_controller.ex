defmodule CodeMySpec.LocalServer.Controllers.AgentTaskController do
  @moduledoc """
  Controller for agent task API endpoints.

  Handles starting and evaluating agent task sessions via HTTP,
  eliminating the BEAM cold start penalty of CLI invocation.
  """

  import Plug.Conn

  alias CodeMySpec.Sessions.AgentTasks.StartAgentTask

  @doc """
  Start an agent task session and return the prompt.

  ## Request Body

  - `external_id` - Claude session ID (required)
  - `session_type` - Type of agent task (required)
  - `module_name` - Component module name (optional, required for component tasks)

  ## Response

  - 200: `{"prompt": "..."}`
  - 400: `{"error": "..."}`
  """
  def start(conn) do
    scope = conn.assigns[:current_scope]
    working_dir = conn.assigns[:working_dir]
    body = conn.body_params

    args = %{
      external_id: body["external_id"],
      session_type: body["session_type"],
      module_name: body["module_name"],
      working_dir: working_dir
    }

    case StartAgentTask.run(scope, args) do
      {:ok, prompt, _sync_result} ->
        json_response(conn, 200, %{prompt: prompt})

      {:error, reason} ->
        json_response(conn, 400, %{error: format_error(reason)})
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
