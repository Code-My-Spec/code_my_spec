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

    Logger.info("[HookController] Body: #{inspect(body)}")

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

  # -- PreToolUse — enrich API calls with session_id -------------------------

  @api_pattern ~r|localhost:400[34]/api/projects/|

  defp handle_event(conn, _scope, "PreToolUse", body) do
    session_id = body["session_id"]
    tool_name = body["tool_name"]

    case tool_name do
      "Bash" ->
        command = get_in(body, ["tool_input", "command"]) || ""

        if Regex.match?(@api_pattern, command) && session_id do
          updated = enrich_command_with_session_id(command, session_id)

          if updated != command do
            Logger.info("[HookController] PreToolUse: enriched curl with session_id")

            json(conn, %{
              "hookSpecificOutput" => %{
                "hookEventName" => "PreToolUse",
                "updatedInput" => %{"command" => updated}
              }
            })
          else
            json(conn, %{})
          end
        else
          json(conn, %{})
        end

      "WebFetch" ->
        url = get_in(body, ["tool_input", "url"]) || ""

        if Regex.match?(@api_pattern, url) && session_id do
          updated = enrich_url_with_session_id(url, session_id)

          if updated != url do
            Logger.info("[HookController] PreToolUse: enriched WebFetch URL with session_id")

            json(conn, %{
              "hookSpecificOutput" => %{
                "hookEventName" => "PreToolUse",
                "updatedInput" => %{"url" => updated}
              }
            })
          else
            json(conn, %{})
          end
        else
          json(conn, %{})
        end

      _ ->
        json(conn, %{})
    end
  end

  # -- PostToolUse — detect start-task calls, assign agent_id ----------------

  defp handle_event(conn, scope, "PostToolUse", body) do
    agent_id = body["agent_id"]

    if agent_id do
      url = extract_start_task_url(body)
      if url, do: assign_agent_from_hook(scope, url, agent_id)
    end

    json(conn, %{})
  end

  # -- Catch-all -------------------------------------------------------------

  defp handle_event(conn, _scope, event, _body) do
    Logger.debug("[HookController] Unhandled event: #{event}")
    json(conn, %{})
  end

  # -- Private ---------------------------------------------------------------

  @start_task_pattern ~r|/sessions/([^/]+)/tasks/([^/]+)/start|

  # Extract start-task URL from any tool use (WebFetch url, Bash curl command, etc.)
  defp extract_start_task_url(body) do
    # Check tool_input.url (WebFetch)
    url = get_in(body, ["tool_input", "url"]) || ""

    cond do
      Regex.match?(@start_task_pattern, url) ->
        url

      # Check tool_input.command (Bash — curl) and tool_response
      true ->
        text = (get_in(body, ["tool_input", "command"]) || "") <>
               (get_in(body, ["tool_response", "stdout"]) || "")

        case Regex.run(@start_task_pattern, text) do
          [match | _] -> match
          nil -> nil
        end
    end
  end

  # Rewrite /next-task to /next-task/:session_id in a URL
  defp enrich_url_with_session_id(url, session_id) do
    if String.contains?(url, session_id) do
      url
    else
      String.replace(url, "/next-task", "/next-task/#{session_id}")
    end
  end

  # Find API URLs in a curl command and enrich with session_id as path segment.
  defp enrich_command_with_session_id(command, session_id) do
    if String.contains?(command, session_id) do
      command
    else
      String.replace(command, "/next-task", "/next-task/#{session_id}")
    end
  end

  defp assign_agent_from_hook(scope, url, agent_id) do
    # Extract session_id and task_id from URL pattern:
    # /api/projects/:name/sessions/:session_id/tasks/:task_id/start
    case Regex.run(~r|/sessions/([^/]+)/tasks/([^/]+)/start|, url) do
      [_, session_id, task_id] ->
        case Sessions.get_session(scope, session_id) do
          %Session{} = session ->
            Sessions.assign_agent(scope, session, task_id, agent_id)

          nil ->
            Logger.warning(
              "[HookController] Session not found for agent assignment: #{session_id}"
            )
        end

      _ ->
        Logger.debug("[HookController] URL did not match start-task pattern: #{url}")
    end
  end
end
