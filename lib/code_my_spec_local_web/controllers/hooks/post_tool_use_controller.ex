defmodule CodeMySpecLocalWeb.Hooks.PostToolUseController do
  @moduledoc """
  Handles the PostToolUse hook — detects start-task calls and assigns agent_id.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  @start_task_pattern ~r|/sessions/([^/]+)/tasks/([^/]+)/start|

  def handle(conn, _params) do
    scope = conn.assigns.current_scope
    body = conn.body_params
    agent_id = body["agent_id"]

    if agent_id do
      url = extract_start_task_url(body)
      if url, do: assign_agent_from_hook(scope, url, agent_id)
    end

    json(conn, %{})
  end

  defp extract_start_task_url(body) do
    url = get_in(body, ["tool_input", "url"]) || ""

    cond do
      Regex.match?(@start_task_pattern, url) ->
        url

      true ->
        text =
          (get_in(body, ["tool_input", "command"]) || "") <>
            (get_in(body, ["tool_response", "stdout"]) || "")

        case Regex.run(@start_task_pattern, text) do
          [match | _] -> match
          nil -> nil
        end
    end
  end

  defp assign_agent_from_hook(scope, url, agent_id) do
    case Regex.run(~r|/sessions/([^/]+)/tasks/([^/]+)/start|, url) do
      [_, session_id, task_id] ->
        case Sessions.get_session(scope, session_id) do
          %Session{} = session ->
            Sessions.assign_agent(scope, session, task_id, agent_id)

          nil ->
            Logger.warning(
              "[PostToolUse] Session not found for agent assignment: #{session_id}"
            )
        end

      _ ->
        Logger.debug("[PostToolUse] URL did not match start-task pattern: #{url}")
    end
  end
end
