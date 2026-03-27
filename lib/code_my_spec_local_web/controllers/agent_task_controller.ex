defmodule CodeMySpecLocalWeb.AgentTaskController do
  @moduledoc """
  Start an agent task and return the prompt.

  Called by plugin skills (e.g. /generate-spec) to add a task to the
  current session and get the work prompt back.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.StartAgentTask

  def start(conn, params) do
    scope = conn.assigns.current_scope

    args = %{
      external_id: params["external_id"],
      session_type: params["session_type"],
      module_name: params["module_name"]
    }

    case StartAgentTask.run(scope, args) do
      {:ok, prompt, _sync_result} ->
        json(conn, %{prompt: prompt})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end
end
