defmodule CodeMySpec.Hooks.Stop do
  @moduledoc """
  The stop hook's decision.

  Resolves session and task, consults persisted Problems, and decides
  block/allow **immediately** — never waiting on a subprocess, so the answer
  always beats the hook's timeout.

  A stop never starts, waits on, or reports analysis: runs come from
  `start_analysis`, ready_for_qa certification and promotion. Analysis
  in flight changes nothing here; the stop answers from the problems already
  persisted, and may still refuse over blocking ones. Results landing after an
  allowed stop reach the user via push notification and block the next stop.

  Lifted out of the local controller so every harness decides identically.
  """

  require Logger

  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Configurations
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Problems
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation
  alias CodeMySpec.AgentTasks.TaskEvaluator

  @total_response_cap 4096

  @doc """
  The stop hook's verdict for a scope and a hook payload.

  Returns the response map the agent receives. Pure with respect to the
  filesystem: whatever had to be run against a working copy has already been
  run by the time this is called.
  """
  @spec decide(CodeMySpec.Users.Scope.t(), map()) :: map()
  def decide(scope, params) do
    session_id = Map.get(params, "session_id")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    # Stamped for the whole request so every line can be grouped by session.
    Logger.metadata(cms_session: session_id, cms_hook: "stop")

    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    session = session_id && Sessions.get_by_external_id(scope, session_id)
    warn_unresolved_session(scope, session_id, session, req_id)

    active_task = session && Session.active_task(session)

    do_decide(scope, session_id, session, active_task, [], req_id)
  end

  # Allow is the default (failing closed on its own plumbing would wedge every
  # agent), but a missing or unknown session is broken configuration, so it
  # warns. A stop before `init_project` has no project yet and stays quiet.
  defp warn_unresolved_session(%{active_project_id: nil}, _session_id, _session, _req_id), do: :ok

  defp warn_unresolved_session(_scope, nil, _session, req_id) do
    Logger.warning(
      "[StopHook] [#{req_id}] no session_id in payload — allowing, but this hook " <>
        "cannot attribute work to a task. Check the hook's --data-binary payload."
    )
  end

  defp warn_unresolved_session(_scope, session_id, nil, req_id) do
    Logger.warning(
      "[StopHook] [#{req_id}] session_id #{session_id} has no session record — " <>
        "allowing, but task evaluation is skipped. Usually a stale MCP connection; " <>
        "reconnect with /mcp or re-fire the session-start hook."
    )
  end

  defp warn_unresolved_session(_scope, _session_id, _session, _req_id), do: :ok

  defp do_decide(scope, session_id, nil, _active_task, validation_opts, req_id) do
    run_and_decide(scope, session_id, nil, nil, validation_opts, req_id)
  end

  defp do_decide(scope, session_id, session, active_task, validation_opts, req_id) do
    cond do
      has_active_subagent_task?(scope, session) ->
        allow(req_id, "Active subagent task")

      continuous_mode?(session) && stuck_threshold_hit?(session) ->
        terminate_stuck(scope, session, req_id)

      has_active_manual_task?(session) ->
        allow(req_id, "Active manual task")

      true ->
        run_and_decide(scope, session_id, session, active_task, validation_opts, req_id)
    end
  end

  defp run_and_decide(scope, session_id, session, active_task, validation_opts, req_id) do
    agent_id = active_task && active_task.agent_id

    opts =
      validation_opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:requested_by, %{
        kind: "hook",
        hook: "stop",
        session_id: session_id,
        agent_id: agent_id
      })

    # Problems never block a stop; promotion is where they gate (John,
    # 2026-10-18). Validation still syncs files and runs the in-process
    # validators.
    {:ok, _result} = Validation.validate_stop(scope, active_task, opts)
    evaluate_and_decide(scope, session_id, session, req_id)
  end

  defp evaluate_and_decide(scope, session_id, session, req_id) do
    case maybe_evaluate(scope, session_id, session) do
      {:ok, :valid} ->
        # cd296681: `session` is the struct `decide/2` fetched before
        # `maybe_evaluate` ran. `:valid` here means TaskEvaluator just
        # closed the active task without error -- including a *failed* QA
        # attempt, which still counts as a validly-recorded evaluation --
        # and that write never reaches this stale struct's own `tasks`
        # association. `Work.actionable/3` and `Menu.render/4` below must
        # see the task as TaskEvaluator just left it, not as it was before
        # this stop hook started, or the menu reports an obstacle ("No
        # valid QA pass attempt in DB") against a task the database
        # already shows as completed.
        session = session && Sessions.get_by_external_id(scope, session_id)
        maybe_continue_with_next_task(scope, session, req_id)

      # Already recorded by `TaskEvaluator`, so nothing to record here — doing
      # it twice would advance the streak two per stop and trip the escape at
      # half the intended threshold.
      {:error, reason} ->
        maybe_terminate_stuck(scope, session_id, reason, req_id)
    end
  end

  # Stuck-detection threshold.
  # See knowledge/analysis, "Stop hook".
  @stuck_threshold 5

  defp stuck_threshold_hit?(%Session{eval_feedback_count: count}) when is_integer(count),
    do: count >= @stuck_threshold

  defp stuck_threshold_hit?(_), do: false

  defp terminate_stuck(scope, session, req_id) do
    count = session.eval_feedback_count || 0

    # Names what repeated without claiming which check produced it: task
    # evaluations and problem blocks both advance the counter.
    message =
      "Continuous mode terminated by stuck-detection: the same stop feedback " <>
        "#{count} times in a row. Whatever was blocking has NOT been fixed — " <>
        "it is still recorded and will block the next run. If it is real but " <>
        "not yours to fix, file it with `create_issue`."

    Logger.info("[StopHook] [#{req_id}] R8 stuck-detection (count=#{count}) — terminating loop")

    # The counter is deliberately not cleared: re-enabling continuous mode
    # without a fix re-trips on the next failure.
    Sessions.update_session(scope, session, %{continuous: false})

    NotificationClient.notify(%{
      type: "stuck",
      title: "Continuous mode terminated — stuck",
      body: message
    })

    # `systemMessage` tells a stuck terminate apart from the "all work
    # complete" allow; both are allows.
    Map.merge(%{"systemMessage" => message}, terminus_retrospective())
  end

  defp maybe_terminate_stuck(scope, nil, reason, req_id),
    do: block_with_reason(scope, reason, req_id)

  defp maybe_terminate_stuck(scope, session_id, reason, req_id) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        block_with_reason(scope, reason, req_id)

      session ->
        case {stuck_threshold_hit?(session), continuous_mode?(session)} do
          {true, true} ->
            terminate_stuck(scope, session, req_id)

          # A non-continuous session gets the same escape: a block that
          # repeats forever is its own outage. Allow, saying nothing was fixed.
          {true, false} ->
            allow_stuck(session, req_id)

          {false, _continuous} ->
            block_with_reason(scope, reason, req_id, session)
        end
    end
  end

  defp allow_stuck(session, req_id) do
    count = session.eval_feedback_count || 0

    Logger.warning(
      "[StopHook] [#{req_id}] same block #{count} times running on a non-continuous " <>
        "session — allowing the stop, unfixed"
    )

    %{
      "systemMessage" =>
        "Allowed after the same block #{count} times in a row. Nothing was fixed — " <>
          "the findings are still recorded and will block again. If they are real but " <>
          "not yours to fix, file them with `create_issue` and tell the user."
    }
  end

  defp block_with_reason(scope, reason, req_id, owner \\ nil) do
    Logger.info("[StopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}",
      cms_decision: "block",
      cms_blocking: blocking_summary(reason)
    )

    hint = harness_hint_footer()
    # No tap-out offer on a refusal: it would offer an exit from the loop this
    # response is holding the agent in.
    menu = Menu.render(scope, false, nil, owner)

    # The menu is budgeted before the findings, so a flood of problems cannot
    # truncate away the directive.
    reason_budget = @total_response_cap - byte_size(hint) - byte_size(menu)
    capped_reason = Problems.truncate_to_cap(reason, cap: reason_budget)

    %{"decision" => "block", "reason" => capped_reason <> menu <> hint}
  end

  # Every block carries this footer so harness friction gets reported, not
  # worked around. The reason is truncated to leave room for it.
  defp harness_hint_footer do
    "\n\nIf this looks like harness friction (looping hook, contradictory prompt, tool error), call `create_issue` with `scope: framework`."
  end

  # Carried by every loop-terminating allow (all work complete, stuck): the
  # agent writes a short retrospective before stopping.
  defp terminus_retrospective do
    %{
      "retrospective" => %{
        "prompt" =>
          "The autonomous loop has terminated. Write a brief retrospective on this run: what worked, what was friction, and any harness issues to file. If you hit any CodeMySpec friction (looping hooks, contradictory prompts, tool errors, missing docs), call `create_issue` with `scope: framework` before you stop.",
        "scope" => "framework"
      }
    }
  end

  defp allow(req_id, label) do
    Logger.info("[StopHook] [#{req_id}] #{label}, allowing stop",
      cms_decision: "allow",
      cms_why: label
    )

    notify_complete()
    %{}
  end

  @doc "Which sources blocked, and how many problems each contributed, as `exunit=1,credo=6`."
  # Parsed from `Validation`'s `source (count):` header in the reason, so a
  # change there shows up as an empty summary rather than a wrong one.
  def blocking_summary(reason) do
    reason
    |> blocking_counts()
    |> Enum.map_join(",", fn {source, count} -> "#{source}=#{count}" end)
  end

  # The per-source counts a block's reason was built from.
  defp blocking_counts(reason) when is_binary(reason) do
    ~r/^\s*(\w+) \((\d+)\)/m
    |> Regex.scan(reason)
    |> Enum.map(fn [_, source, count] -> {source, String.to_integer(count)} end)
  end

  defp blocking_counts(_), do: []

  defp maybe_evaluate(_scope, _session_id, nil), do: {:ok, :valid}

  defp maybe_evaluate(scope, session_id, _session) do
    TaskEvaluator.evaluate_sessions(scope, session_id)
  end

  # A parent is exempt while a subagent holding an active task (non-nil
  # `agent_id`) is live by heartbeat (`Session.active_subagents/2`, the same
  # source `list_session_subagents` reports). A task row alone is not evidence:
  # it outlives a killed subagent.
  defp has_active_subagent_task?(scope, session) do
    subagent_task_live?(session, live_agent_ids(scope, session))
  end

  @doc """
  Public, and split from the lookup, so the rule can be asserted without a
  database: the interesting cases are all about which agent ids are live, and
  `Configurations.get_or_create/1` inserts on miss.
  """
  @spec subagent_task_live?(Session.t(), MapSet.t(String.t())) :: boolean()
  def subagent_task_live?(session, live_agent_ids) do
    Enum.any?(session.tasks || [], fn task ->
      task.status == :active and not is_nil(task.agent_id) and
        MapSet.member?(live_agent_ids, task.agent_id)
    end)
  end

  defp live_agent_ids(scope, session) do
    ttl = Configurations.get_or_create(scope).subagent_ttl_minutes

    session
    |> Session.active_subagents(ttl)
    |> MapSet.new(& &1.agent_id)
  end

  defp has_active_manual_task?(session) do
    case Session.active_task(session) do
      %{validation_type: :manual} -> true
      _ -> false
    end
  end

  # The loop keeps the agent working; it does not tell it what to work on. The
  # refusal is `Menu.render/4`, the same menu every refusal uses.
  # See knowledge/analysis, "Stop hook".
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
        # The same count the menu renders, so the decision and the menu in one
        # response cannot disagree.
        case length(Work.actionable(scope, nil, session)) do
          n when n > 0 ->
            Logger.info(
              "[StopHook] [#{req_id}] Continuous mode, more work available, blocking stop"
            )

            %{
              "decision" => "block",
              "reason" =>
                "Task completed successfully, and the loop is still running." <>
                  Menu.render(scope, true, nil, session)
            }

          0 ->
            Logger.info("[StopHook] [#{req_id}] All work complete, allowing stop")
            notify_complete()
            terminus_retrospective()
        end
    end
  end

  defp continuous_mode?(%{continuous: true}), do: true
  defp continuous_mode?(_), do: false

  defp notify_complete do
    NotificationClient.notify(%{
      type: "task_complete",
      title: "Claude has finished",
      body: "Claude Code has completed its current task"
    })
  end
end
