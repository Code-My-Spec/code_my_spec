defmodule CodeMySpec.Hooks.Stop do
  @moduledoc """
  The stop hook's decision.

  Resolves the terminal agent and its task, consults persisted Problems, and decides
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

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.AgentTasks.TaskEvaluator
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Problems
  alias CodeMySpec.Validation

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

    case Agents.take_held_for_stop(scope, session_id) do
      [] ->
        agent = owner(scope, session_id)
        warn_unresolved_session(scope, session_id, agent, req_id)

        active_task = agent && Agent.active_task(agent)

        do_decide(scope, session_id, agent, active_task, [], req_id)

      messages ->
        hand_over(messages, req_id)
    end
  end

  # The terminal agent a Claude Code session is, fresh from the row, or nil.
  defp owner(scope, session_id) do
    case Agents.fetch_owner(scope, nil, session_id) do
      {:ok, agent} -> agent
      {:error, _reason} -> nil
    end
  end

  # A terminal agent nothing else can reach is told at its stop (story 1123).
  defp hand_over(messages, req_id) do
    Logger.info("[StopHook] [#{req_id}] Handing over #{length(messages)} held message(s)",
      cms_decision: "block"
    )

    %{
      "decision" => "block",
      "reason" =>
        "Messages for you, held until you stopped because they could not reach this " <>
          "session directly:\n\n" <> Enum.map_join(messages, "\n\n---\n\n", & &1)
    }
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
      "[StopHook] [#{req_id}] session_id #{session_id} is no registered agent — " <>
        "allowing, but task evaluation is skipped. Usually a session whose start hook " <>
        "never fired; restart it or re-fire the session-start hook."
    )
  end

  defp warn_unresolved_session(_scope, _session_id, _session, _req_id), do: :ok

  defp do_decide(scope, session_id, nil, _active_task, validation_opts, req_id) do
    run_and_decide(scope, session_id, nil, nil, validation_opts, req_id)
  end

  defp do_decide(scope, session_id, agent, active_task, validation_opts, req_id) do
    cond do
      continuous_mode?(agent) && stuck_threshold_hit?(agent) ->
        terminate_stuck(scope, agent, req_id)

      has_active_manual_task?(agent) ->
        allow(req_id, "Active manual task")

      true ->
        run_and_decide(scope, session_id, agent, active_task, validation_opts, req_id)
    end
  end

  defp run_and_decide(scope, session_id, agent, _active_task, validation_opts, req_id) do
    opts =
      validation_opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:agent_id, nil)
      |> Keyword.put(:git_rewrite_at, agent && agent.git_rewrite_at)
      |> Keyword.put(:requested_by, %{
        kind: "hook",
        hook: "stop",
        session_id: session_id,
        agent_id: nil
      })

    # Problems never block a stop; promotion is where they gate (John,
    # 2026-10-18). Validation still syncs files and runs the in-process
    # validators.
    {:ok, _result} = Validation.validate_stop(scope, agent && Agent.active_task(agent), opts)
    evaluate_and_decide(scope, session_id, agent, req_id)
  end

  defp evaluate_and_decide(scope, session_id, agent, req_id) do
    case maybe_evaluate(scope, agent) do
      {:ok, :valid} ->
        # cd296681: `agent` is the struct `decide/2` fetched before
        # `maybe_evaluate` ran. `:valid` here means TaskEvaluator just
        # closed the active task without error -- including a *failed* QA
        # attempt, which still counts as a validly-recorded evaluation --
        # and that write never reaches this stale struct's own `tasks`
        # list. `Work.actionable/3` and `Menu.render/4` below must
        # see the task as TaskEvaluator just left it, not as it was before
        # this stop hook started, or the menu reports an obstacle ("No
        # valid QA pass attempt in DB") against a task the database
        # already shows as completed.
        agent = agent && owner(scope, session_id)
        maybe_continue_with_next_task(scope, agent, req_id)

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

  # The same failure text this many stops running, counted on the active task.
  defp stuck_threshold_hit?(%Agent{} = agent), do: feedback_count(agent) >= @stuck_threshold
  defp stuck_threshold_hit?(_), do: false

  defp feedback_count(%Agent{} = agent) do
    case Agent.active_task(agent) do
      %{evaluation_feedback_count: count} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp terminate_stuck(scope, agent, req_id) do
    count = feedback_count(agent)

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
    Agents.set_agent_continuous(scope, agent.id, false)

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
    case owner(scope, session_id) do
      nil ->
        block_with_reason(scope, reason, req_id)

      agent ->
        case {stuck_threshold_hit?(agent), continuous_mode?(agent)} do
          {true, true} ->
            terminate_stuck(scope, agent, req_id)

          # A non-continuous agent gets the same escape: a block that
          # repeats forever is its own outage. Allow, saying nothing was fixed.
          {true, false} ->
            allow_stuck(agent, req_id)

          {false, _continuous} ->
            block_with_reason(scope, reason, req_id, agent)
        end
    end
  end

  defp allow_stuck(agent, req_id) do
    count = feedback_count(agent)

    Logger.warning(
      "[StopHook] [#{req_id}] same block #{count} times running on a non-continuous " <>
        "agent — allowing the stop, unfixed"
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

  defp maybe_evaluate(_scope, nil), do: {:ok, :valid}
  defp maybe_evaluate(scope, %Agent{} = agent), do: TaskEvaluator.evaluate_agent(scope, agent)

  defp has_active_manual_task?(agent) do
    case Agent.active_task(agent) do
      %{validation_type: :manual} -> true
      _ -> false
    end
  end

  # The loop keeps the agent working; it does not tell it what to work on. The
  # refusal is `Menu.render/4`, the same menu every refusal uses.
  # See knowledge/analysis, "Stop hook".
  defp maybe_continue_with_next_task(scope, agent, req_id) do
    cond do
      is_nil(agent) ->
        Logger.info("[StopHook] [#{req_id}] No agent, allowing stop")
        notify_complete()
        %{}

      not continuous_mode?(agent) ->
        Logger.info("[StopHook] [#{req_id}] Not in continuous mode, allowing stop")
        notify_complete()
        %{}

      true ->
        # The same count the menu renders, so the decision and the menu in one
        # response cannot disagree.
        case length(Work.actionable(scope, role_of(agent), agent)) do
          n when n > 0 ->
            Logger.info(
              "[StopHook] [#{req_id}] Continuous mode, more work available, blocking stop"
            )

            %{
              "decision" => "block",
              "reason" =>
                "Task completed successfully, and the loop is still running." <>
                  Menu.render(scope, true, role_of(agent), agent)
            }

          0 ->
            Logger.info("[StopHook] [#{req_id}] All work complete, allowing stop")
            notify_complete()
            terminus_retrospective()
        end
    end
  end

  # A terminal main is offered main's own work, not the graph's development
  # requirements; any other terminal agent works the whole graph, as a session
  # always did.
  defp role_of(%Agent{role: :main}), do: :main
  defp role_of(_owner), do: nil

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
