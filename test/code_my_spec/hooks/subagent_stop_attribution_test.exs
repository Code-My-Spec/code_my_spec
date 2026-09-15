defmodule CodeMySpec.Hooks.SubagentStopAttributionTest do
  @moduledoc """
  A sub-agent stop must attribute findings the same way a main stop does.

  `SubagentStop.handle/2` called `Validation.validate_stop(scope, task)` — two
  arguments. `validate_stop/3` defaults `opts` to `[]`, and `session_paths/2`
  reads the session id out of `opts`, so it took the "no session id" branch and
  answered `nil`. `nil` renders "Attribution is unavailable for this session, so
  nothing could be demoted and every finding blocks".

  So demotion had never worked on this path for any sub-agent, in any session:
  `log_demotions` lines carry `cms_hook=stop` and never `cms_hook=subagent_stop`.
  Two agents sat blocked for hours on twelve findings in stories neither had
  touched, each with a correct in-project edit recorded against its own agent id.

  The main-stop path was never affected, which is what made this hard to see —
  the same session demoted correctly on `stop` and blocked on `subagent_stop`
  minutes apart.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @session "subagent-stop-attribution-session"

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()

    {1, _rows} =
      Files.upsert_files(scope, [
        %{path: "lib/touched.ex", role: :implementation, fingerprint: "a", valid: true}
      ])

    :ok = FileEdits.track_edit(@session, "lib/touched.ex")

    %{scope: scope}
  end

  # The opts the hook builds are the whole subject here, so they are asserted
  # against the same function the hook feeds rather than a copy of it.
  describe "the opts a sub-agent stop forwards" do
    test "carrying the session id yields a usable attribution set", ctx do
      paths = Validation.session_paths_for_test(ctx.scope, session_id: @session)

      refute is_nil(paths),
             "nil is the bug: it renders as 'attribution unavailable' and blocks everything"

      assert MapSet.member?(paths, "lib/touched.ex")
    end

    # Pins the defaulted-opts shape the hook used to produce. If this ever stops
    # answering nil the bug above stops being detectable by the test beneath it.
    test "dropping them is what produced the blocking answer", ctx do
      assert is_nil(Validation.session_paths_for_test(ctx.scope, []))
    end
  end

  describe "SubagentStop" do
    # Reads the call itself. There is no injection seam on `validate_stop/3`, and
    # the failure is entirely in what the caller passes — a behavioural test would
    # need the full problem/analysis fixture to observe a difference that is
    # already fully determined here.
    test "passes the session id through to validation" do
      source = File.read!("lib/code_my_spec/hooks/subagent_stop.ex")

      assert source =~ ~r/Validation\.validate_stop\(\s*scope,\s*task,/,
             """
             SubagentStop calls validate_stop/2, so opts default to [] and every
             sub-agent stop reports attribution unavailable and blocks on findings
             it did not cause. It must forward session_id and agent_id.
             """

      assert source =~ ~r/session_id:\s*session_id/
      assert source =~ ~r/agent_id:\s*agent_id/
    end
  end

  describe "SubagentStop task evaluation is scoped to the stopping agent" do
    # Same shape as the attribution bug above, one call further down the same
    # hook: `find_task_by_agent/2` correctly resolves a task scoped to this
    # sub-agent's own `agent_id`, and then evaluation threw that away and
    # asked `TaskEvaluator.evaluate_sessions/2` instead -- which reads
    # `Session.active_task/1`, the first task on the *session* with
    # `status: :active`, no agent scoping at all. A session accumulates tasks
    # across every agent that has ever worked it, so one left `:active` and
    # unfinished -- from a different agent, a different day -- was evaluated
    # against every new sub-agent's stop regardless of what that sub-agent
    # was actually doing. Observed live: an ad-hoc research fork with no task
    # of its own, blocked on a three-day-old `FixIssues` task nothing had
    # asked it to work (`8904f4ec`).
    #
    # No injection seam here either (same note as above), so this pins the
    # call site rather than exercising the full DB-backed path.
    test "evaluates the agent-scoped task, not the session's" do
      source = File.read!("lib/code_my_spec/hooks/subagent_stop.ex")

      refute source =~ ~r/TaskEvaluator\.evaluate_sessions\(/,
             """
             evaluate_sessions/2 re-derives the task via Session.active_task/1,
             which has no agent scoping -- it finds the first :active task on the
             whole session, from any agent, and evaluates every sub-agent's stop
             against it regardless of what that sub-agent was asked to do.
             """

      assert source =~ ~r/TaskEvaluator\.evaluate_task\(/,
             "the task find_task_by_agent/2 already resolved must be the one evaluated"
    end

    test "a sub-agent with no task of its own is allowed, not evaluated against the session's" do
      source = File.read!("lib/code_my_spec/hooks/subagent_stop.ex")

      assert source =~ ~r/defp maybe_evaluate\(_scope, _session, nil\), do: \{:ok, :valid\}/,
             "nil task (no match for this agent_id) must allow, the same as evaluate_session/3 does"
    end
  end
end
