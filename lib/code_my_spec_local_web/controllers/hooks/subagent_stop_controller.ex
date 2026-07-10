defmodule CodeMySpecLocalWeb.Hooks.SubagentStopController do
  @moduledoc """
  Handles the SubagentStop hook event.

  Resolves the subagent's task via agent_id, runs validation (in-process
  validators + background analyzer enqueue), then evaluates. The decision is
  made immediately from persisted Problems — analysis still in flight allows
  the stop with a one-line system message; results land in the background and
  apply to the parent's next stop.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Analysis
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

    # Story 704 / Rule 1: unregister the sub-agent on stop. Best-effort
    # and idempotent — no-op if the agent_id isn't currently registered.
    if session && agent_id, do: Sessions.unregister_subagent(scope, session, agent_id)

    case Validation.validate_stop(scope, task) do
      {:error, reason} ->
        Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
        json(conn, %{"decision" => "block", "reason" => reason})

      {:ok, _result} ->
        json(conn, decide_after_validation(scope, session_id, session, req_id))
    end
  end

  # Analysis pending → skip evaluation (freshness-gated "not run yet"
  # feedback must not bump R8 counters) and allow — the parent's next stop
  # blocks on any problems that land.
  defp decide_after_validation(scope, session_id, session, req_id) do
    if scope.active_project_id && Analysis.runs_in_flight?(scope) do
      sources = scope |> Analysis.in_flight() |> Enum.join(", ")
      Logger.info("[SubagentStopHook] [#{req_id}] Analysis pending (#{sources}) — allowing stop")
      %{"systemMessage" => "analysis running: #{sources} — results apply next stop"}
    else
      case maybe_evaluate(scope, session_id, session) do
        {:error, reason} ->
          Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
          %{"decision" => "block", "reason" => reason}

        {:ok, :valid} ->
          Logger.info("[SubagentStopHook] [#{req_id}] Allowing stop")
          %{}
      end
    end
  end

  defp maybe_evaluate(_scope, _session_id, nil), do: {:ok, :valid}

  defp maybe_evaluate(scope, session_id, _session) do
    TaskEvaluator.evaluate_sessions(scope, session_id)
  end
end
