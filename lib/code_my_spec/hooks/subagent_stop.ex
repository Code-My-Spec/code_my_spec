defmodule CodeMySpec.Hooks.SubagentStop do
  @moduledoc """
  The SubagentStop hook — decide whether a sub-agent may stop.

  Same shape as the main stop decision and the same reasoning: what ran needs a
  working copy, what the result means needs only the database.
  """

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation
  alias CodeMySpec.Validation.TaskEvaluator

  @spec handle(CodeMySpec.Users.Scope.t(), map()) :: {pos_integer(), map()}
  def handle(scope, params) do
    session_id = Map.get(params, "session_id")
    agent_id = Map.get(params, "agent_id")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    # Same trace as `Stop`, and the one that fires more often: a delegating
    # agent produces many sub-agent stops per main stop, so this is where the
    # shape of a run is actually visible. `cms_agent` distinguishes them within
    # one session.
    Logger.metadata(cms_session: session_id, cms_agent: agent_id, cms_hook: "subagent_stop")

    Logger.info("[SubagentStopHook] [#{req_id}] session: #{session_id}, agent: #{agent_id}")

    # Resolve session + subagent task
    session = session_id && Sessions.get_by_external_id(scope, session_id)
    task = session && Session.find_task_by_agent(session, agent_id)

    # Story 704 / Rule 1: unregister the sub-agent on stop. Best-effort
    # and idempotent — no-op if the agent_id isn't currently registered.
    if session && agent_id, do: Sessions.unregister_subagent(scope, session, agent_id)

    # Three elements, not two. `validate_stop/3` has carried R8's blocking key
    # since the stuck-detection change, and this clause kept matching the old
    # pair — so every sub-agent stop that had something to block on raised
    # `CaseClauseError` instead. The key is `Stop`'s to count; nothing here
    # needs it, but the arity is not optional.
    # And the opts, which are what `session_paths/2` reads the session id out of.
    # Omitted, `opts` defaulted to `[]` and every sub-agent stop answered "attribution
    # unavailable" and blocked on every finding in the project — never once demoting,
    # for any sub-agent. `Stop` forwards them (stop.ex:233); this did not.
    requested_by = %{kind: "hook", hook: "subagent_stop", session_id: session_id, agent_id: agent_id}

    case Validation.validate_stop(scope, task,
           session_id: session_id,
           agent_id: agent_id,
           requested_by: requested_by
         ) do
      {:error, reason, _blocking_key} ->
        Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}",
          cms_decision: "block",
          cms_blocking: Stop.blocking_summary(reason)
        )

        {200, %{"decision" => "block", "reason" => reason}}

      {:ok, _result} ->
        {200, decide_after_validation(scope, session_id, session, req_id)}
    end
  end

  # Analysis pending → skip evaluation (freshness-gated "not run yet"
  # feedback must not bump R8 counters) and allow — the parent's next stop
  # blocks on any problems that land.
  defp decide_after_validation(scope, session_id, session, req_id) do
    if scope.active_project_id && Analysis.runs_in_flight?(scope) do
      sources = scope |> Analysis.in_flight() |> Enum.join(", ")
      Logger.info("[SubagentStopHook] [#{req_id}] Analysis pending (#{sources}) — allowing stop",
        cms_decision: "allow",
        cms_why: "analysis pending"
      )
      %{"systemMessage" => "analysis running: #{sources} — results apply next stop"}
    else
      case maybe_evaluate(scope, session_id, session) do
        {:error, reason} ->
          Logger.info("[SubagentStopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}",
            cms_decision: "block",
            cms_blocking: Stop.blocking_summary(reason)
          )

          %{"decision" => "block", "reason" => reason}

        {:ok, :valid} ->
          Logger.info("[SubagentStopHook] [#{req_id}] Allowing stop",
            cms_decision: "allow",
            cms_why: "task evaluated clean"
          )
          %{}
      end
    end
  end

  defp maybe_evaluate(_scope, _session_id, nil), do: {:ok, :valid}

  defp maybe_evaluate(scope, session_id, _session) do
    TaskEvaluator.evaluate_sessions(scope, session_id)
  end
end
