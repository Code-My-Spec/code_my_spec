defmodule CodeMySpecLocalWeb.Hooks.SubagentStopController do
  @moduledoc """
  Handles the SubagentStop hook event.

  Resolves the subagent's task via agent_id, runs validation pipeline,
  then evaluates. Blocks on compiler errors, otherwise allows stop.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation
  alias CodeMySpec.Validation.TaskEvaluator

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")
    agent_id = Map.get(params, "agent_id")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[SubagentStopHook] [#{req_id}] session: #{session_id}, agent: #{agent_id}")

    # Resolve session + subagent task
    session = session_id && Sessions.get_by_external_id(scope, session_id)
    task = session && Session.find_task_by_agent(session, agent_id)

    # Run validation pipeline
    case Validation.validate_stop(scope, task) do
      {:error, reason} ->
        Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
        json(conn, %{"decision" => "block", "reason" => reason})

      {:ok, _result} ->
        # Evaluate task requirements
        case maybe_evaluate(scope, session_id, session) do
          {:error, reason} ->
            Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
            json(conn, %{"decision" => "block", "reason" => reason})

          {:ok, :valid} ->
            Logger.info("[SubagentStopHook] [#{req_id}] Allowing stop")
            json(conn, %{})
        end
    end
  end

  defp maybe_evaluate(_scope, _session_id, nil), do: {:ok, :valid}

  defp maybe_evaluate(scope, session_id, _session) do
    TaskEvaluator.evaluate_sessions(scope, session_id)
  end
end
