defmodule CodeMySpecLocalWeb.HookController do
  @moduledoc """
  Dispatches Claude Code hook events.

  All hooks POST the full payload to `/api/hooks` with X-Working-Dir.
  This controller routes by `hook_event_name`.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  def dispatch(conn, _params) do
    scope = conn.assigns.current_scope
    body = conn.body_params
    event = body["hook_event_name"] || "unknown"

    Logger.info("[HookController] Event: #{event}")

    handle_event(conn, scope, event, body)
  end

  # -- SessionStart ----------------------------------------------------------

  defp handle_event(conn, scope, "SessionStart", body) do
    session_id = body["session_id"]

    if is_nil(session_id) or session_id == "" do
      conn |> put_status(400) |> json(%{error: "session_id is required"})
    else
      case Sessions.find_or_create_session(scope, session_id) do
        {:ok, session} ->
          json(conn, %{session_id: session.id, status: to_string(session.status)})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    end
  end

  # -- PostToolUse (WebFetch) — assign agent_id to active task ---------------

  defp handle_event(conn, scope, "PostToolUse", body) do
    tool_name = body["tool_name"]
    url = get_in(body, ["tool_input", "url"]) || ""
    agent_id = body["agent_id"]

    if tool_name == "WebFetch" && String.contains?(url, "/tasks/") && String.contains?(url, "/start") && agent_id do
      assign_agent_from_hook(scope, url, agent_id)
    end

    json(conn, %{})
  end

  # -- Catch-all -------------------------------------------------------------

  defp handle_event(conn, _scope, event, _body) do
    Logger.debug("[HookController] Unhandled event: #{event}")
    json(conn, %{})
  end

  # -- Private ---------------------------------------------------------------

  defp assign_agent_from_hook(scope, url, agent_id) do
    # Extract session_id and task_id from URL pattern:
    # /api/projects/:name/sessions/:session_id/tasks/:task_id/start
    case Regex.run(~r|/sessions/([^/]+)/tasks/([^/]+)/start|, url) do
      [_, session_id, task_id] ->
        case Sessions.get_session(scope, session_id) do
          %Session{} = session ->
            Sessions.assign_agent(scope, session, task_id, agent_id)

          nil ->
            Logger.warning("[HookController] Session not found for agent assignment: #{session_id}")
        end

      _ ->
        Logger.debug("[HookController] URL did not match start-task pattern: #{url}")
    end
  end
end
