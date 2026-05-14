defmodule CodeMySpecLocalWeb.Hooks.StopController do
  @moduledoc """
  Handles the Stop hook event.

  Thin HTTP layer: resolves session/task, calls Validation (sync + compile +
  analyze), calls TaskEvaluator (pure DB read), decides block/allow.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation
  alias CodeMySpec.Validation.TaskEvaluator

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")
    validation_opts = extract_test_output_files(params)

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    session = session_id && Sessions.get_by_external_id(scope, session_id)
    active_task = session && Session.active_task(session)
    # Computed once here so the cond below doesn't pay the
    # Configurations.get_or_create cost (which inserts on miss) twice
    # for the R5b decision.
    idle_sub = session && idle_subagent_for(scope, session)

    response = decide(scope, session_id, session, active_task, idle_sub, validation_opts, req_id)

    json(conn, response)
  end

  defp decide(scope, session_id, session, active_task, idle_sub, validation_opts, req_id) do
    cond do
      session && has_active_subagent_task?(session) ->
        allow(req_id, "Active subagent task")

      session && r5b_applies?(session, active_task, idle_sub) ->
        block_assign_directive(active_task, idle_sub, req_id)

      session && continuous_mode?(session) && stuck_threshold_hit?(active_task) ->
        terminate_stuck(scope, session, active_task, req_id)

      session && has_active_manual_task?(session) ->
        allow(req_id, "Active manual task")

      true ->
        run_and_decide(scope, session_id, session, active_task, validation_opts, req_id)
    end
  end

  # R5b — Continuous mode + a still-open main-agent task + an alive idle
  # sub-agent: hand the work off so the main agent can stop and further
  # stops happen via the sub-agent's own lifecycle. Without continuous
  # mode, the regular allow path fires; R5b never preempts a one-shot
  # stop.
  defp r5b_applies?(session, active_task, idle_sub) do
    continuous_mode?(session) and
      not is_nil(active_task) and
      not is_nil(idle_sub)
  end

  # Returns the first alive sub-agent on the session whose agent_id is
  # not currently assigned to any active task, or nil. A nil scope
  # project_id (stop hook fires before a project is bound) short-circuits
  # to nil so `Configurations.get_or_create` — which requires a project —
  # never raises here.
  defp idle_subagent_for(%{active_project_id: nil}, _session), do: nil

  defp idle_subagent_for(scope, session) do
    ttl = Configurations.get_or_create(scope).subagent_ttl_minutes

    assigned_ids =
      (session.tasks || [])
      |> Enum.filter(&(&1.status == :active and not is_nil(&1.agent_id)))
      |> Enum.map(& &1.agent_id)
      |> MapSet.new()

    session
    |> Session.active_subagents(ttl)
    |> Enum.find(&(not MapSet.member?(assigned_ids, &1.agent_id)))
  end

  defp block_assign_directive(active_task, idle_sub, req_id) do
    Logger.info(
      "[StopHook] [#{req_id}] R5b: idle sub-agent #{idle_sub.agent_id} + open task → assign directive"
    )

    %{
      "decision" => "block",
      "reason" => """
      A sub-agent is idle while task `#{active_task.id}` is still open. Hand the work off so the main agent can stop — further stops will happen via the sub-agent's own lifecycle.

      Call `assign_subagent` with task_id=`#{active_task.id}` agent_id=`#{idle_sub.agent_id}`.
      """
    }
  end

  defp run_and_decide(scope, session_id, session, active_task, validation_opts, req_id) do
    with {:ok, _result} <- Validation.validate_stop(scope, active_task, validation_opts),
         {:ok, :valid} <- maybe_evaluate(scope, session_id, session) do
      maybe_continue_with_next_task(scope, session, req_id)
    else
      {:error, reason} ->
        maybe_terminate_stuck(scope, session_id, reason, req_id)
    end
  end

  # R8 — stuck-detection. Two check points share `terminate_stuck/4`:
  # (a) `decide/7` checks `active_task.failure_count` BEFORE the manual
  #     short-circuit, so manual-task loops bumped by `EvaluateTask`
  #     MCP calls can still terminate.
  # (b) `maybe_terminate_stuck/4` checks AFTER evaluate has run inside
  #     this stop, so auto-task loops bumped by `TaskEvaluator` in the
  #     same request also terminate. The re-fetch via
  #     `get_by_external_id` is what makes (b) see the count
  #     `TaskEvaluator` just incremented during this request.
  # At threshold: clear continuous, notify, return empty allow.
  # Below threshold: fall through to block-with-feedback.
  @stuck_threshold 5

  defp stuck_threshold_hit?(nil), do: false

  defp stuck_threshold_hit?(%{failure_count: count}) when is_integer(count),
    do: count >= @stuck_threshold

  defp stuck_threshold_hit?(_), do: false

  defp terminate_stuck(scope, session, active_task, req_id) do
    count = active_task.failure_count || 0

    message =
      "Continuous mode terminated by stuck-detection: task #{active_task.id} " <>
        "failed evaluate_task #{count} times in a row."

    Logger.info("[StopHook] [#{req_id}] R8 stuck-detection (count=#{count}) — terminating loop")

    # `failure_count` is intentionally NOT reset here. If the user
    # later re-enables continuous mode on the same active task without
    # resolving it, the very next stop will re-terminate — the loop
    # stays stuck until the task is completed, cancelled, or replaced.
    Sessions.update_session(scope, session, %{continuous: false})

    NotificationClient.notify(%{
      type: "stuck",
      title: "Continuous mode terminated — stuck",
      body: message
    })

    # `systemMessage` lets the agent — and the spex — discriminate
    # an R8 terminate from an R6 "all work complete" allow. Both
    # paths return an allow (no `decision: block`), but only R8 names
    # the stuck-detection reason here.
    %{"systemMessage" => message}
  end

  defp maybe_terminate_stuck(_scope, nil, reason, req_id),
    do: block_with_reason(reason, req_id)

  defp maybe_terminate_stuck(scope, session_id, reason, req_id) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        block_with_reason(reason, req_id)

      session ->
        active = Session.active_task(session)

        if continuous_mode?(session) and stuck_threshold_hit?(active),
          do: terminate_stuck(scope, session, active, req_id),
          else: block_with_reason(reason, req_id)
    end
  end

  defp block_with_reason(reason, req_id) do
    Logger.info("[StopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
    %{"decision" => "block", "reason" => reason}
  end

  defp allow(req_id, label) do
    Logger.info("[StopHook] [#{req_id}] #{label}, allowing stop")
    notify_complete()
    %{}
  end

  defp maybe_evaluate(_scope, _session_id, nil), do: {:ok, :valid}

  defp maybe_evaluate(scope, session_id, _session) do
    TaskEvaluator.evaluate_sessions(scope, session_id)
  end

  # A task owned by a sub-agent has a non-nil `agent_id` — the claim set
  # by the sub-agent's `start_task` or by `assign_subagent` (Story 704).
  # `execution_type: :sub_agent` on the requirement only declares the
  # intended directive shape ("Spawn a sub-agent…"); the runtime owner is
  # whoever holds the `agent_id`. When the main agent starts a
  # :sub_agent-typed requirement directly, the task stays main-agent
  # owned until an assignment lands.
  defp has_active_subagent_task?(session) do
    Enum.any?(session.tasks || [], fn task ->
      task.status == :active and not is_nil(task.agent_id)
    end)
  end

  defp has_active_manual_task?(session) do
    case Session.active_task(session) do
      %{validation_type: :manual} -> true
      _ -> false
    end
  end

  defp maybe_continue_with_next_task(scope, session, req_id) do
    cond do
      is_nil(session) ->
        Logger.info("[StopHook] [#{req_id}] No session, allowing stop")
        notify_complete()
        %{}

      not continuous_mode?(session) ->
        Logger.info("[StopHook] [#{req_id}] Not in continuous mode, allowing stop")
        notify_complete()
        %{}

      true ->
        case RequirementGraph.next_actionable(scope) do
          [_ | _] = nodes ->
            Logger.info(
              "[StopHook] [#{req_id}] Continuous mode, more work available, blocking stop"
            )

            directive = RequirementsMapper.format_next_requirements(nodes)

            %{
              "decision" => "block",
              "reason" => """
              Task completed successfully. Continuing the autonomous loop with the next assignment:

              #{directive}
              """
            }

          [] ->
            Logger.info("[StopHook] [#{req_id}] All work complete, allowing stop")
            notify_complete()
            %{}
        end
    end
  end

  defp continuous_mode?(%{continuous: true}), do: true
  defp continuous_mode?(_), do: false

  # Test-only: specs back pipeline outputs with pre-recorded JSON fixtures
  # so cassette replays can observe failures (`System.cmd` side effects —
  # the JSON output files — can't be captured by ExCliVcr alone).
  # Real Claude Code clients never send this param; the map is ignored
  # when absent.
  defp extract_test_output_files(%{"test_output_files" => files}) when is_map(files) do
    [
      compile_output_file: Map.get(files, "compile"),
      exunit_output_file: Map.get(files, "exunit"),
      spex_output_file: Map.get(files, "spex")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp extract_test_output_files(_params), do: []

  defp notify_complete do
    NotificationClient.notify(%{
      type: "task_complete",
      title: "Claude has finished",
      body: "Claude Code has completed its current task"
    })
  end
end
