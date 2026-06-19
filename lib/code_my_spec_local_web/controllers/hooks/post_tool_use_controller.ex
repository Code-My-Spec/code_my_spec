defmodule CodeMySpecLocalWeb.Hooks.PostToolUseController do
  @moduledoc """
  Handles the PostToolUse hook.

  Persists every Write/Edit/MultiEdit/NotebookEdit tool invocation as a
  `FileEdit` row keyed on `(external_session_id, agent_id, file_path)`
  so the stop hook can scope its block decision to files this session
  and agent actually touched — instead of every file dirty on disk,
  which leaks across parallel sessions.

  `agent_id` is `nil` for main-agent edits and a UUID for Task-spawned
  sub-agent edits. Tracking is fire-and-forget: the controller always
  responds with `%{}` so tool execution proceeds even if persistence
  fails.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope

  @edit_tools ~w(Write Edit MultiEdit NotebookEdit)

  def handle(conn, params) do
    track_edit(params)
    mark_active(conn, params)
    json(conn, %{})
  end

  # Every tool call means this session is doing work: touch its updated_at
  # so the agent-progress view can derive "active" by recency on load (and
  # refresh open pages live). Fire-and-forget.
  defp mark_active(conn, %{"session_id" => session_id}) when is_binary(session_id) do
    with %Scope{} = scope <- conn.assigns[:current_scope],
         session when not is_nil(session) <- Sessions.get_by_external_id(scope, session_id) do
      Sessions.touch_session(scope, session)
    else
      _ -> :ok
    end
  end

  defp mark_active(_conn, _params), do: :ok

  defp track_edit(%{
         "tool_name" => tool,
         "tool_input" => input,
         "session_id" => session_id
       } = params)
       when tool in @edit_tools and is_binary(session_id) do
    agent_id = Map.get(params, "agent_id")

    case extract_file_path(input) do
      {:ok, file_path} ->
        FileEdits.track_edit(session_id, file_path, agent_id)

        Logger.info(
          "[PostToolUse] tracked #{tool} session=#{session_id} agent=#{agent_id || "main"} path=#{file_path}"
        )

      :error ->
        Logger.debug("[PostToolUse] #{tool} fired but no file_path in tool_input")
    end
  end

  defp track_edit(_params), do: :ok

  defp extract_file_path(%{"file_path" => file_path}) when is_binary(file_path),
    do: {:ok, file_path}

  defp extract_file_path(%{"notebook_path" => path}) when is_binary(path), do: {:ok, path}
  defp extract_file_path(_input), do: :error
end
