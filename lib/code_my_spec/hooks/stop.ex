defmodule CodeMySpec.Hooks.Stop do
  @moduledoc """
  The stop hook's decision.

  Resolves session and task, consults persisted Problems, and decides
  block/allow **immediately** — never waiting on a subprocess, so the answer
  always beats the hook's timeout.

  While background analysis is in flight the stop is a distinct *pending*
  outcome: task evaluation is skipped (a repeat "analysis running" must not
  advance the stuck counter) and the "all work complete" terminus never fires
  (freshness-gated requirements would read as unsatisfied mid-run). In
  continuous mode a pending stop blocks with a directive to wait on
  `POST /api/harnesses/<id>/analysis/wait` (HTTP, not MCP — a sweep outlives
  MCP's 30s request cap, so the tool this replaced could never return);
  otherwise it allows with a one-line system message. Results landing after an
  allowed stop reach the user via push notification and block the next stop.

  Lifted out of the local controller so every harness decides identically. The
  controller that calls this owns running the analyzers; this owns reading what
  they produced.
  """

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Configurations
  alias CodeMySpec.FileEdits
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation
  alias CodeMySpec.Validation.Menu
  alias CodeMySpec.Validation.TaskEvaluator

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
    validation_opts = extract_test_output_files(params)

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    # Stamped for the whole request, so every line this hook emits carries the
    # session rather than only the first. Analysing where an agent gets stuck
    # means grouping stops by session, and a prose line that names it once
    # cannot be grouped without joining on request id first.
    Logger.metadata(cms_session: session_id, cms_hook: "stop")

    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    session = session_id && Sessions.get_by_external_id(scope, session_id)
    warn_unresolved_session(scope, session_id, session, req_id)

    active_task = session && Session.active_task(session)
    # Computed once here so the cond below doesn't pay the
    # Configurations.get_or_create cost (which inserts on miss) twice
    # for the R5b decision.
    idle_sub = session && idle_subagent_for(scope, session)

    scope
    |> do_decide(session_id, session, active_task, idle_sub, validation_opts, req_id)
    |> note_config_edits(session_id)
  end

  # There was a second half to this, and it is gone: a `note_stale_config/1`
  # that compared the sha this server booted at against the sha on disk and
  # warned when the range touched config/. It caught the case
  # `note_config_edits/2` structurally cannot — a config change arriving by
  # `git pull`, which nobody's session edited.
  #
  # It paid for that by shelling out to `git rev-parse` inside every stop, which
  # is a fork per hook for a question almost always answered "no". It also broke
  # twenty-one spex across eight unrelated stories: the spex cassettes patch
  # `System.cmd/3` process-globally, so a stray `git` call inside a request dies
  # on `No recording found for: git rev-parse --short HEAD` and takes the
  # criterion with it, naming a boot version in a story about something else.
  #
  # The warning was worth having and the price was not. If it comes back it
  # comes back off the harness's file watcher, which already knows when the
  # checkout moves and does not have to ask.

  # Phoenix cannot hot-reload `config/*.exs`, by design. A commit that touches
  # one leaves every running dev server answering
  #
  #     ** (RuntimeError) could not compile application: code_my_spec.
  #     You must restart your server after changing configuration files
  #
  # to every request — but not here, and not now. It surfaces in a different
  # checkout, minutes later, to whoever touches it next, and nothing in that
  # error names the commit. Two servers went down at once from two unrelated
  # sessions, neither of whom did anything wrong (5fb011f4, 6ecb257a).
  #
  # On allow only. An allow is the agent walking away, which is exactly when the
  # wedge starts costing somebody else; a block already tells it to come back,
  # and repeating this on every one of those would train it to skip the footer.
  defp note_config_edits(%{"decision" => "block"} = response, _session_id), do: response

  defp note_config_edits(response, session_id) when is_binary(session_id) do
    case session_id |> FileEdits.get_edited_files() |> Enum.filter(&config_file?/1) do
      [] ->
        response

      paths ->
        note =
          "You edited #{Enum.join(Enum.sort(paths), ", ")}. Phoenix cannot " <>
            "hot-reload config, so every running dev server — including ones in " <>
            "other checkouts, once this reaches them — will answer every request " <>
            "with a CompileError until it is restarted. Restarting alone does not " <>
            "always clear it: kill the BEAM, `rm -rf _build/<env>/lib/<app>` to " <>
            "drop the stale compile.lock, then relaunch."

        Map.update(response, "systemMessage", note, &(&1 <> "\n\n" <> note))
    end
  end

  defp note_config_edits(response, _session_id), do: response

  # `config/<name>.exs` at the project root, whether the recorded path is
  # relative or absolute — PostToolUse stores whatever Claude passed, and both
  # shapes occur.
  defp config_file?(path) when is_binary(path) do
    segments = Path.split(path)

    String.ends_with?(path, ".exs") and
      Path.basename(Path.dirname(path)) == "config" and
      "deps" not in segments and "_build" not in segments
  end

  defp config_file?(_path), do: false

  # Allow stays the default — a stop hook that fails closed on its own
  # plumbing would wedge every agent on this machine. But allowing silently
  # means a hook that never sends `session_id`, or one pointed at a session
  # this server has no record of, succeeds forever and looks identical to a
  # healthy run. Nothing here is per-turn noise: both cases are broken
  # configuration, and an unattended run is exactly where nobody is watching
  # the 200s go by.
  #
  # A stop before `init_project` is not broken — there is no project to hold
  # sessions yet — so that one stays quiet.
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

  defp do_decide(scope, session_id, nil, _active_task, _idle_sub, validation_opts, req_id) do
    run_and_decide(scope, session_id, nil, nil, validation_opts, req_id)
  end

  defp do_decide(scope, session_id, session, active_task, idle_sub, validation_opts, req_id) do
    cond do
      has_active_subagent_task?(session) ->
        allow(req_id, "Active subagent task")

      r5b_applies?(session, active_task, idle_sub) ->
        block_assign_directive(active_task, idle_sub, req_id)

      continuous_mode?(session) && stuck_threshold_hit?(session) ->
        terminate_stuck(scope, session, req_id)

      has_active_manual_task?(session) ->
        allow(req_id, "Active manual task")

      true ->
        run_and_decide(scope, session_id, session, active_task, validation_opts, req_id)
    end
  end

  # R5b — A still-open main-agent task + an alive idle sub-agent: hand
  # the work off so the main agent can stop and further stops happen via
  # the sub-agent's own lifecycle. This applies regardless of continuous
  # mode — the assign-from-outside flow lets the parent set agent_id on
  # the task BEFORE its own stop, so the R5a short-circuit (active task
  # with agent_id → allow) fires next turn. Without this rule firing
  # outside continuous mode, a parent that spawns a subagent for a
  # one-shot QA pass loses the race between subagent registration and
  # the parent's stop, falls through to validation, and gets blocked on
  # "Brief not found." Issue b597bbca.
  defp r5b_applies?(_session, active_task, idle_sub) do
    not is_nil(active_task) and not is_nil(idle_sub)
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
    opts =
      validation_opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:agent_id, active_task && active_task.agent_id)

    case Validation.validate_stop(scope, active_task, opts) do
      # Persisted problems already block — no need to wait on anything.
      #
      # `key` is what makes R8 reach this path at all. The counter it reads was
      # only ever bumped by `TaskEvaluator`, so a stop blocked purely on
      # problems repeated forever with the escape sitting right here, wired up
      # and never armed. Recorded on the finding set rather than the rendered
      # text — see `Validation.blocking_key/1`.
      {:error, reason, key} ->
        maybe_terminate_stuck(scope, session_id, reason, req_id, key)

      {:ok, _result} ->
        if pending_analysis?(scope),
          do: pending_response(scope, session, req_id),
          else: evaluate_and_decide(scope, session_id, session, req_id)
    end
  end

  defp evaluate_and_decide(scope, session_id, session, req_id) do
    case maybe_evaluate(scope, session_id, session) do
      {:ok, :valid} ->
        maybe_continue_with_next_task(scope, session, req_id)

      # Already recorded by `TaskEvaluator`, so nothing to record here — doing
      # it twice would advance the streak two per stop and trip the escape at
      # half the intended threshold.
      {:error, reason} ->
        maybe_terminate_stuck(scope, session_id, reason, req_id, nil)
    end
  end

  # Analysis in flight → a distinct pending outcome. Evaluation is skipped
  # entirely: a freshness-gated "tests not run yet" failure repeated across
  # stops must not advance the R8 stuck counter, and R6's "all work complete"
  # must not fire off requirements that are only unsatisfied because their
  # analyzer hasn't landed. The scope's cwd being nil (no project bound)
  # never reaches here pending — ensure_stale_runs enqueues nothing.
  defp pending_analysis?(%{active_project_id: nil}), do: false
  defp pending_analysis?(scope), do: Analysis.runs_in_flight?(scope)

  # The address carries the harness id, because the wait endpoint is on the
  # harness and every harness route names the working copy it is about. A scope
  # with no harness has no local address to offer, so it gets the plain
  # instruction rather than a URL that would 404.
  defp wait_directive(%{active_harness_id: id}) when not is_nil(id) do
    "Wait for it with `curl -sS -X POST localhost:4004/api/harnesses/#{id}/analysis/wait` " <>
      "— run that in the background and you will be notified when it returns — then stop again."
  end

  defp wait_directive(_scope) do
    "Wait for the analyzers to finish, then stop again."
  end

  defp pending_response(scope, session, req_id) do
    sources = scope |> Analysis.in_flight() |> Enum.join(", ")

    if continuous_mode?(session) do
      Logger.info("[StopHook] [#{req_id}] Analysis pending (#{sources}) — directing await")

      %{
        "decision" => "block",
        "reason" => "Background analysis is still running: #{sources}. " <> wait_directive(scope)
      }
    else
      Logger.info("[StopHook] [#{req_id}] Analysis pending (#{sources}) — allowing stop")

      %{
        "systemMessage" => "analysis running: #{sources} — results apply next stop"
      }
    end
  end

  # R8 — stuck-detection. Two check points share `terminate_stuck/3`:
  # (a) `decide/7` checks `session.eval_feedback_count` BEFORE the
  #     manual short-circuit, so manual-task loops bumped by
  #     `EvaluateTask` MCP calls can still terminate.
  # (b) `maybe_terminate_stuck/4` checks AFTER evaluate has run inside
  #     this stop, so auto-task loops bumped by `TaskEvaluator` in the
  #     same request also terminate. The re-fetch via
  #     `get_by_external_id` is what makes (b) see the count
  #     `TaskEvaluator` just incremented during this request.
  # At threshold: clear continuous, notify, return empty allow.
  # Below threshold: fall through to block-with-feedback.
  @stuck_threshold 5

  defp stuck_threshold_hit?(%Session{eval_feedback_count: count}) when is_integer(count),
    do: count >= @stuck_threshold

  defp stuck_threshold_hit?(_), do: false

  defp terminate_stuck(scope, session, req_id) do
    count = session.eval_feedback_count || 0

    # Names what repeated without claiming which check produced it. The counter
    # is now advanced by two things — a task evaluation returning the same
    # feedback, and a stop blocked on the same finding set — and a message that
    # says `evaluate_task` for both sends anyone reading it to the wrong place.
    message =
      "Continuous mode terminated by stuck-detection: the same stop feedback " <>
        "#{count} times in a row. Whatever was blocking has NOT been fixed — " <>
        "it is still recorded and will block the next run. If it is real but " <>
        "not yours to fix, file it with `create_issue`."

    Logger.info("[StopHook] [#{req_id}] R8 stuck-detection (count=#{count}) — terminating loop")

    # Stuck-detection state is intentionally NOT cleared here. If the
    # user later re-enables continuous mode without resolving the
    # underlying problem, the very next failure will re-trip — the
    # loop stays stuck until a different feedback or a passing eval
    # clears the counter via `record_eval_feedback` / `clear_eval_feedback`.
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
    Map.merge(%{"systemMessage" => message}, terminus_retrospective())
  end

  defp maybe_terminate_stuck(scope, nil, reason, req_id, _key),
    do: block_with_reason(scope, reason, req_id)

  defp maybe_terminate_stuck(scope, session_id, reason, req_id, key) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        block_with_reason(scope, reason, req_id)

      session ->
        session = record_block(scope, session, key)

        cond do
          continuous_mode?(session) and stuck_threshold_hit?(session) ->
            terminate_stuck(scope, session, req_id)

          # The same escape for a session that was never continuous. The
          # threshold used to be gated on continuous mode because
          # `terminate_stuck/3` ends a *loop*, and a session with no loop had
          # nothing to end — but the block repeats there just the same, and an
          # interactive agent hit it five times with no legitimate move left.
          #
          # "A block that repeats forever is its own outage" is the reasoning
          # `HookDecision`'s second pass already runs on, and it does not depend
          # on who started the run. So this allows the stop and says, loudly,
          # that nothing was fixed — rather than turning off a loop that is not
          # running.
          stuck_threshold_hit?(session) ->
            allow_stuck(session, req_id)

          true ->
            block_with_reason(scope, reason, req_id)
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

  # A block on problems, counted the same way a repeated task-evaluation
  # failure is. The finding set is the identity: the same problems next stop
  # advance the streak, a fixed or new one resets it, and waiting for a lagging
  # analyzer does neither.
  #
  # Without this a genuine finding the working agent cannot resolve — one
  # belonging to another story, or to work that is not implemented — blocked
  # every stop with nothing legitimate for the agent to do. Eight in a row was
  # observed; unattended it spends the whole budget.
  defp record_block(_scope, session, nil), do: session

  defp record_block(scope, session, key) do
    case Sessions.record_eval_feedback(scope, session, key) do
      {:ok, updated} -> updated
      _ -> session
    end
  end

  defp block_with_reason(scope, reason, req_id) do
    Logger.info("[StopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}",
      cms_decision: "block",
      cms_blocking: blocking_summary(reason)
    )

    hint = harness_hint_footer()
    menu = Menu.render(scope)

    # The menu's bytes come off the budget before the findings, not after, so a
    # flood of problems cannot truncate away the one part of the response that
    # says what to do. The findings are what truncation is for — losing the last
    # three of forty costs nothing, losing the directive costs the whole point.
    reason_budget = @total_response_cap - byte_size(hint) - byte_size(menu)
    capped_reason = Problems.truncate_to_cap(reason, cap: reason_budget)
    %{"decision" => "block", "reason" => capped_reason <> menu <> hint}
  end

  # R9 — every block-with-feedback reason carries a one-line affordance
  # pointing the agent at the framework-issue surface so harness friction
  # gets reported instead of worked around. The reason is truncated to
  # leave room for this footer so the whole response stays under the
  # @total_response_cap.
  defp harness_hint_footer do
    "\n\nIf this looks like harness friction (looping hook, contradictory prompt, tool error), call `create_issue` with `scope: framework`."
  end

  # R7 — terminus payload carried by every loop-terminating allow (R6
  # graph-empty and R8 stuck-detection). The agent is expected to write
  # a short retrospective before stopping; the `scope` hint points at the
  # framework-issue surface for any harness friction observed during the
  # run.
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

  @doc false
  # Which sources blocked, and how many problems each contributed, as
  # `exunit=1,credo=6`.
  #
  # Read back out of the reason text rather than threaded down from the
  # validator: the reason is already built from exactly this, and threading it
  # through six call sites to avoid one regex would be the more fragile of the
  # two. The shape it parses is `Validation`'s own header — `source (count):` —
  # so a change there shows up here as an empty summary rather than a wrong one.
  #
  # This is the field that answers the question worth asking about an
  # onboarding agent: not "did it get blocked" but "on what, repeatedly".
  def blocking_summary(reason) when is_binary(reason) do
    ~r/^\s*(\w+) \((\d+)\)/m
    |> Regex.scan(reason)
    |> Enum.map_join(",", fn [_, source, count] -> "#{source}=#{count}" end)
  end

  def blocking_summary(_), do: ""

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
        # Same answer as a resolvable session, deliberately. What is available
        # to do is a fact about the working copy, not about whether this stop
        # could be tied to a session row — and a payload that names no session
        # taking a different path is exactly how a skipped validation hides.
        Logger.info("[StopHook] [#{req_id}] No session, allowing stop")
        notify_complete()
        allow_with_menu(scope)

      not continuous_mode?(session) ->
        # Told, not refused. A first cut blocked here whenever any class was
        # live, and story 555's, 538's and 983's criteria caught it in one run:
        # seven scenarios across three stories specify that a clean pipeline is
        # allowed to stop. Refusing on an outstanding backlog is continuous
        # mode, and continuous mode is opt-in — an interactive agent would never
        # have been able to stop while any work remained anywhere.
        #
        # So the menu rides the allow as a system message. The agent still hears
        # what is available; it is simply not held for it.
        Logger.info("[StopHook] [#{req_id}] Not in continuous mode, allowing stop")
        notify_complete()
        allow_with_menu(scope)

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
            terminus_retrospective()
        end
    end
  end

  defp continuous_mode?(%{continuous: true}), do: true
  defp continuous_mode?(_), do: false

  # An allow that still says what is waiting. `%{}` when the menu is empty, so a
  # terminal stop stays literally silent — a "nothing to do" message on the one
  # stop that has nothing to do is the noise this whole change exists to remove.
  defp allow_with_menu(scope) do
    case Menu.render(scope) do
      "" -> %{}
      menu -> %{"systemMessage" => String.trim_leading(menu)}
    end
  end

  # Test-only: specs back pipeline outputs with pre-recorded JSON fixtures
  # so cassette replays can observe failures (`System.cmd` side effects —
  # the JSON output files — can't be captured by ExCliVcr alone).
  # Real Claude Code clients never send this param; the map is ignored
  # when absent.
  defp extract_test_output_files(%{"test_output_files" => files}) when is_map(files) do
    [
      compile_output_file: Map.get(files, "compile"),
      credo_output_file: Map.get(files, "credo"),
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
