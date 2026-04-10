defmodule CodeMySpecLocalWeb.Hooks.SubagentStopController do
  @moduledoc """
  Handles the SubagentStop hook event.

  Delegates to TaskEvaluator.evaluate_stop/3 with the agent_id option to
  resolve the subagent's task. Blocks on compiler errors, otherwise allows stop.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Validation.TaskEvaluator

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")
    agent_id = Map.get(params, "agent_id")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[SubagentStopHook] [#{req_id}] session: #{session_id}, agent: #{agent_id}")

    case TaskEvaluator.evaluate_stop(scope, session_id, agent_id: agent_id) do
      {:error, reason} ->
        Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
        json(conn, %{"decision" => "block", "reason" => reason})

      _ ->
        Logger.info("[SubagentStopHook] [#{req_id}] Allowing stop")
        json(conn, %{})
    end
  end
end
