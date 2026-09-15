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
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements
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

    do_decide(scope, session_id, session, active_task, validation_opts, req_id)
  end

  # The stop hook used to warn about config edits, in two halves, and both are
  # gone. `note_config_edits/2` appended a footer on allow when the session had
  # edited `config/*.exs`; `note_stale_config/1` compared the sha this server
  # booted at against the one on disk, and caught the case the first structurally
  # could not - a config change arriving by a pull, which nobody's session
  # edited.
  #
  # `note_stale_config/1` went first, for cost: it shelled out to a subprocess
  # inside every stop - a fork per hook for a question almost always answered
  # "no" - and it broke twenty-one spex across eight unrelated stories, because
  # the spex cassettes patch `System.cmd/3` process-globally and a stray call
  # inside a request dies on a missing recording, taking the criterion with it.
  #
  # `note_config_edits/2` went second, and for a different reason: it does not
  # reach the audience it is written for. The footer rides on the stop hook, so
  # it is read by a Claude Code session and by nothing else - an agent running
  # inside our own BEAM fires no stop hook and never sees it. The wedge it warns
  # about costs *other checkouts*, minutes later, which is precisely who cannot
  # be told this way. John's call, 2026-09-15.
  #
  # If the warning comes back it comes back off the harness's file watcher, which
  # already knows when a checkout moves, does not have to ask, and can reach
  # every copy rather than the one whose session happened to make the edit.

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

  # There was an R5b here: an open main-agent task plus any idle sub-agent
  # blocked the stop with "assign that sub-agent to that task".
  #
  # Its predicate was `not is_nil(active_task) and not is_nil(idle_sub)` and
  # `idle_subagent_for/2` returned the *first* registered sub-agent not already
  # holding a task. Neither asked whether the two had anything to do with each
  # other, because the rule was written when a session had one sub-agent and one
  # task, where the pairing is true by accident.
  #
  # It stopped being true. On 2026-08-22 a session spawned a read-only Explore
  # agent to grep the repo, and the hook told the main agent — twice, as an
  # exact tool call to copy — to hand it a `qa_complete` task for an unrelated
  # story whose own agent had finished hours earlier. Following that directive
  # files a QA verdict from an agent that never opened a browser. Issue
  # 958fbfaf.
  #
  # The race this was written for (b597bbca: a sub-agent registers, the parent
  # stops before `start_task` sets `agent_id`, validation runs against a brief
  # that does not exist yet) is real but wants a fix that knows which task
  # belongs to which agent. Guessing is worse than the race.

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

      {:ok, result} ->
        response =
          if pending_analysis?(scope),
            do: pending_response(scope, session, req_id),
            else: evaluate_and_decide(scope, session_id, session, req_id)

        note_assignment(response, result)
    end
  end

  # What an allowed stop says about findings that are not its problem.
  #
  # Story 895's rule 3 — a working copy surfaces every finding about it,
  # regardless of assignment. A red spex on another checkout's story is advisory
  # here, correctly, and until this the stop that let it through said nothing at
  # all about it. That is the half of the rule that is easy to lose: assignment
  # decides whose stop a finding refuses, never whether anybody hears about it.
  #
  # Only on an allow. A block already carries the same sentence inside its
  # reason, and saying it twice in one response is worse than saying it once.
  defp note_assignment(%{"decision" => "block"} = response, _result), do: response

  defp note_assignment(response, %{advisory_note: note}) when is_binary(note) do
    Map.update(response, "systemMessage", note, &(&1 <> "\n\n" <> note))
  end

  defp note_assignment(response, _result), do: response

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
  defp wait_directive(%{active_working_copy_id: id}) when not is_nil(id) do
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
            block_with_reason(scope, reason, req_id, continuous_mode?(session), session)
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

  defp block_with_reason(scope, reason, req_id, continuous? \\ false, owner \\ nil) do
    Logger.info("[StopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}",
      cms_decision: "block",
      cms_blocking: blocking_summary(reason)
    )

    hint = harness_hint_footer()
    menu = Menu.render(scope, continuous?, nil, owner)

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

  @doc "Which sources blocked, and how many problems each contributed, as `exunit=1,credo=6`."
  # Read back out of the reason text rather than threaded down from the
  # validator: the reason is already built from exactly this, and threading it
  # through six call sites to avoid one regex would be the more fragile of the
  # two. The shape it parses is `Validation`'s own header — `source (count):` —
  # so a change there shows up here as an empty summary rather than a wrong one.
  #
  # This is the field that answers the question worth asking about an
  # onboarding agent: not "did it get blocked" but "on what, repeatedly".
  def blocking_summary(reason) do
    reason
    |> blocking_counts()
    |> Enum.map_join(",", fn {source, count} -> "#{source}=#{count}" end)
  end

  # The per-source counts a block's reason was built from. Two readers now: the
  # log line above, and the count on the transcript entry, which has to be this
  # decision's own finding rather than the project's standing backlog (QA 985).
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

  # A task owned by a sub-agent has a non-nil `agent_id` — the claim set
  # by the sub-agent's `start_task` or by `assign_subagent` (Story 704).
  # `execution_type: :sub_agent` on the requirement only declares the
  # intended directive shape ("Spawn a sub-agent…"); the runtime owner is
  # whoever holds the `agent_id`. When the main agent starts a
  # :sub_agent-typed requirement directly, the task stays main-agent
  # owned until an assignment lands.
  # An open task is not evidence that a subagent is working.
  #
  # This exemption exists so the stop hook does not hammer a parent while a
  # subagent is mid-flight, which is right. It keyed on `task.status == :active
  # and agent_id != nil`, and a task row outlives the agent that owned it: a
  # subagent that is killed, crashes, or is stopped by the operator never
  # completes its task, so the row stays `:active` for ever and the parent is
  # exempt from every check for the rest of the session.
  #
  # Measured 2026-08-20 on this session. Two rows said subagents were working:
  #
  #     ● qa_complete — [active] agent=qa-873b
  #     ● qa_complete — [active] agent=aqa-727-8475683e9d966b73
  #
  # Both belonged to QA subagents the operator had stopped hours earlier.
  # `list_session_subagents` — which filters by `subagent_ttl_minutes` —
  # answered "No registered sub-agents on this session" at the same moment. The
  # registrations were right and the task rows were tombstones, and the parent
  # spent hours unable to be blocked by anything, including a failing spex suite
  # that was stopping another agent on the same project.
  #
  # So the question is asked of the thing that expires. `Session.active_subagents/2`
  # already filters on `last_heartbeat_at` against the configured TTL, and is
  # what `list_session_subagents` reports from — one source for "who is working
  # here", rather than two that can disagree.
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

  # The loop keeps the agent working; it does not tell it what to work on.
  #
  # This used to inline `format_next_requirements/1` — the graph's own pick,
  # rendered as "the next assignment". John, 2026-09-05: *"I'm dubious our
  # orchestrator will make better decisions than the model with the upcoming
  # requirements and some reasoning."*
  #
  # That is the right way round. The graph ranks by topology and knows nothing
  # about what this agent just learned finishing the last task, what is
  # half-written on disk, or which of four equally actionable requirements is
  # the one whose context is already loaded. The model has all of that, and
  # `list_requirements` and `get_next_requirement` are one call away.
  #
  # It also ends a contradiction the loop shipped with:
  # `StartImplementation.command/2` opens continuous mode with "Call
  # `get_next_requirement` to find your next task", and every stop after that
  # took the decision back.
  #
  # So the refusal is `Menu.render/2` — story 894's main menu, the same one
  # every other refusal uses. That gets the class ordering right for free
  # (problems before issues before requirements, criterion 2400) rather than
  # sending an agent to `get_next_requirement` while findings are outstanding,
  # which is what a hand-written directive here would have done.
  #
  # `actionable_count/1` rather than `next_actionable/1`, and the difference is
  # not tidiness. `Menu`'s own comment records why: `next_actionable/1`
  # recomputes on a cache miss and globs the working copy, and for a
  # harness-served project the stop decision runs *inside the channel process*
  # — so the process that would serve the glob is the one waiting on it. The
  # read model answers the same question without touching the filesystem, and
  # it is the count `Menu` is about to render, so the decision and the message
  # can no longer disagree.
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
        # The same count the menu renders two lines below, and deliberately.
        #
        # `NodeRepository.actionable_count/1` reads `n.satisfied` straight from
        # the rows, which now hold the *durable* verdict — a component's own
        # problem count, without the analysis-freshness qualifier that
        # `RequirementGraph.serve/2` applies on the way to a reader. So a
        # `tests_passing` whose run has gone stale reads satisfied here and
        # unsatisfied in the menu: this branch would tell a continuous agent its
        # work was finished while the menu in the same response listed the work.
        # Criterion 3448 is what forbids those two disagreeing.
        case Requirements.actionable_count(scope, nil) do
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
