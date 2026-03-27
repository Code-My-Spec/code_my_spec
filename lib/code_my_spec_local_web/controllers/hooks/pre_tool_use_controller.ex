defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook — enriches API calls with session_id.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  @api_pattern ~r|localhost:400[34]/api/projects/|

  def handle(conn, _params) do
    body = conn.body_params
    session_id = body["session_id"]
    tool_name = body["tool_name"]

    case tool_name do
      "Bash" ->
        handle_bash(conn, body, session_id)

      "WebFetch" ->
        handle_web_fetch(conn, body, session_id)

      _ ->
        json(conn, %{})
    end
  end

  defp handle_bash(conn, body, session_id) do
    command = get_in(body, ["tool_input", "command"]) || ""

    if Regex.match?(@api_pattern, command) && session_id do
      updated = enrich_command_with_session_id(command, session_id)

      if updated != command do
        Logger.info("[PreToolUse] Enriched curl with session_id")

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
  end

  defp handle_web_fetch(conn, body, session_id) do
    url = get_in(body, ["tool_input", "url"]) || ""

    if Regex.match?(@api_pattern, url) && session_id do
      updated = enrich_url_with_session_id(url, session_id)

      if updated != url do
        Logger.info("[PreToolUse] Enriched WebFetch URL with session_id")

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
  end

  defp enrich_url_with_session_id(url, session_id) do
    if String.contains?(url, session_id) do
      url
    else
      String.replace(url, "/next-task", "/next-task/#{session_id}")
    end
  end

  defp enrich_command_with_session_id(command, session_id) do
    if String.contains?(command, session_id) do
      command
    else
      String.replace(command, "/next-task", "/next-task/#{session_id}")
    end
  end
end
