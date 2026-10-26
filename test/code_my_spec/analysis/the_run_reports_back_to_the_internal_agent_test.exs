defmodule CodeMySpec.Analysis.TheRunReportsBackToTheInternalAgentTest do
  @moduledoc """
  Two consumers of one analyzer result, and they are not variations of a thing.

  An **external** agent — Claude Code — keeps running and fires hooks. It is
  offered a wait endpoint and collects the digest on its next tool call through
  `Hooks.AnalysisAlert`. A pull.

  An **internal** agent — Alloy, in our own BEAM — has a process we can reach.
  It starts a run, ends its turn, and is told when the run lands. A push, and
  the thing that did not exist: the prompt handed it a `curl` and it spent a
  turn holding a command open on a sweep that runs for minutes.

  John: "when we run analysis, the agent should stop, we should run analysis,
  and then when it's done running analysis it should message the Alloy agent
  back."
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}

    %{scope: scope, copy: copy}
  end

  defp agent(scope, copy, engine, role \\ "coding") do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        continuous: true,
        engine: engine,
        role: role,
        working_copy: "/tmp/report-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    agent
  end

  defp problem(severity), do: %{severity: severity, source: "spex"}

  test "a run with errors reports back to the agent", ctx do
    agent = agent(ctx.scope, ctx.copy, :alloy)

    AnalysisReport.deliver(ctx.scope, "spex", [problem(:error), problem(:error)])

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == agent.id
    assert message =~ "spex run finished"
    assert message =~ "2 blocking problems"
    assert message =~ "list_problems"
  end

  # 3bbc3a94: the notice and `list_problems` disagreed in both directions, and
  # neither said which run it was about.
  test "the notice names its run, and a full run's findings are in list_problems", ctx do
    agent(ctx.scope, ctx.copy, :alloy)
    run = %{id: 61_117, kind: :full, commit: "5edce7faa00012345", exit_status: 2, listed?: true}

    AnalysisReport.deliver(ctx.scope, "exunit", [problem(:error)], nil, run)

    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "exunit run finished (run 61117 at 5edce7faa000): 1 blocking problem"
    assert message =~ "Call `list_problems`"
  end

  test "a targeted run's findings are read from its output, not list_problems", ctx do
    agent(ctx.scope, ctx.copy, :alloy)
    run = %{id: 61_414, kind: :partial, commit: nil, exit_status: 2, listed?: false}

    AnalysisReport.deliver(ctx.scope, "exunit", [problem(:error), problem(:error)], nil, run)

    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "not in `list_problems`"
    assert message =~ "get_analysis_output({run_id = 61414})"
  end

  test "a run that exited non-zero with nothing parsed is not announced clean", ctx do
    asker = agent(ctx.scope, ctx.copy, :alloy)
    run = %{id: 63_229, kind: :full, commit: "48e723257709", exit_status: 1, listed?: true}

    AnalysisReport.deliver(ctx.scope, "spex", [], asker.id, run)

    assert_receive {:agent_dispatch, _id, _ref, message}
    refute message =~ "no blocking problems"
    assert message =~ "exit status 1"
    assert message =~ "get_analysis_output({run_id = 63229})"
  end

  # Criterion 3046. A message wakes a process and costs it a turn, and an agent
  # woken to be told its tree is clean has been charged for no information.
  test "a clean run says nothing", ctx do
    agent(ctx.scope, ctx.copy, :alloy)

    AnalysisReport.deliver(ctx.scope, "spex", [])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  # 4a4cb998: this counted errors only, so a run whose warnings blocked
  # certification told its asker "no problems". Counted by the gate's own rule.
  test "a compiler warning is reported as blocking", ctx do
    agent(ctx.scope, ctx.copy, :alloy)

    AnalysisReport.deliver(ctx.scope, "compiler", [%{severity: :warning, source: "compiler"}])

    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "compiler run finished: 1 blocking problem"
  end

  # Advisory never blocks (John, 2026-10-04): it wakes no one, and the asker
  # hears it counted as advisory rather than called clean or dirty.
  test "advisory findings alone wake no one, and the asker is told they are advisory", ctx do
    bystander = agent(ctx.scope, ctx.copy, :alloy)
    asker = agent(ctx.scope, ctx.copy, :alloy)
    bystander_id = bystander.id

    AnalysisReport.deliver(ctx.scope, "credo", [%{severity: :info, source: "credo"}], asker.id)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == asker.id
    assert message =~ "no blocking problems in this working copy (1 advisory)"
    refute_receive {:agent_dispatch, ^bystander_id, _ref, _message}, 100
  end

  # The other consumer has its own path. Telling it here as well would tell it
  # twice — once now and once on its next tool call.
  test "a Claude Code agent in the same copy is not told here", ctx do
    agent(ctx.scope, ctx.copy, :claude_code)

    AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  test "every internal agent in the copy is told", ctx do
    one = agent(ctx.scope, ctx.copy, :alloy)
    two = agent(ctx.scope, ctx.copy, :alloy)

    AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)])

    assert_receive {:agent_dispatch, first, _, _}
    assert_receive {:agent_dispatch, second, _, _}
    assert Enum.sort([first, second]) == Enum.sort([one.id, two.id])
  end

  # It runs inside `Reconciler.reconcile/4`, after the run is recorded. A
  # delivery that cannot land must not make a completed run look incomplete.
  test "a copy with no agents is not an error", ctx do
    assert AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)]) == :ok
  end

  test "a scope with no working copy is not an error", ctx do
    scope = %{ctx.scope | active_working_copy_id: nil}

    assert AnalysisReport.deliver(scope, "spex", [problem(:error)]) == :ok
  end

  describe "the agent that asked for the run" do
    # `@report_roles` answers "who should hear about findings nobody asked for".
    # It was also deciding "who may be answered about a run they started", which
    # is a different question — `tell_one/4` already distinguishes them, and its
    # requester clause could never fire for a role outside the list because the
    # query removed the asker first.
    #
    # Measured 2026-09-23: a QA agent on Broken Oaths story 947 started credo and
    # spex, both rows carrying its agent_id, both completed at 16:02. It held its
    # task waiting and was never told, because :qa is not a report role. Fifty
    # minutes, ended by a person noticing.
    test "is answered even when its role is not a report role", ctx do
      qa = agent(ctx.scope, ctx.copy, :alloy, "qa")

      AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)], qa.id)

      assert_receive {:agent_dispatch, id, _ref, _message}

      assert id == qa.id,
             """
             The asker was filtered out of its own answer by the broadcast role
             list, so an agent that started a run and waited on it was never
             told the run had finished.
             """
    end

    test "is answered on a clean run, which is the case it most needs", ctx do
      qa = agent(ctx.scope, ctx.copy, :alloy, "qa")

      AnalysisReport.deliver(ctx.scope, "spex", [], qa.id)

      assert_receive {:agent_dispatch, id, _ref, message}
      assert id == qa.id

      assert message =~ "no blocking problems in this working copy",
             "a green run is still an answer to whoever asked for it"
    end

    test "a non-asking agent outside the report roles still hears nothing", ctx do
      _qa = agent(ctx.scope, ctx.copy, :alloy, "qa")

      AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)], nil)

      refute_receive {:agent_dispatch, _id, _ref, _message}, 500
    end

    # `f2ff4147`: a Claude Code session writes its own session id, not an
    # `agents.id`, to `run.requested_by["agent_id"]`. `internal_agents/3`
    # compared it against `a.id` (a `:binary_id` column) unconditionally,
    # which raised trying to dump a non-UUID string and failed the whole run's
    # report — every compiler and credo run a CLI session asked for. The
    # requester is not one of this copy's alloy agents either way, so this
    # must fall back to the ordinary broadcast rather than crash it.
    test "a requester id that is not a real agent's id does not crash the report", ctx do
      coding = agent(ctx.scope, ctx.copy, :alloy, "coding")

      AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)], "not-a-uuid-session-id")

      assert_receive {:agent_dispatch, id, _ref, _message}
      assert id == coding.id
    end

    # Issue cdf54b03: a terminal coder called evaluate_task, was told its fix
    # was waiting on a spex run, and said it would complete once that run
    # landed. The run finished clean 40 minutes later and nothing woke it —
    # the "other path" the bystander test above relies on (its own Stop hook,
    # on its next turn) never ran, because the agent had no next turn to run
    # it on. An asker gets no other notice, whatever engine it runs on.
    test "a terminal (Claude Code) agent is answered when it is the one that asked", ctx do
      terminal = agent(ctx.scope, ctx.copy, :claude_code, "coding")

      AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)], terminal.id)

      assert_receive {:agent_dispatch, id, _ref, message}
      assert id == terminal.id
      assert message =~ "spex run finished"
    end

    test "a terminal agent that did not ask still hears nothing, even beside one that did", ctx do
      bystander = agent(ctx.scope, ctx.copy, :claude_code, "coding")
      asker = agent(ctx.scope, ctx.copy, :claude_code, "coding")
      bystander_id = bystander.id

      AnalysisReport.deliver(ctx.scope, "spex", [problem(:error)], asker.id)

      assert_receive {:agent_dispatch, id, _ref, _message}
      assert id == asker.id
      refute_receive {:agent_dispatch, ^bystander_id, _ref, _message}, 100
    end

    test "a terminal agent also hears a failed run it asked about", ctx do
      terminal = agent(ctx.scope, ctx.copy, :claude_code, "coding")

      AnalysisReport.deliver_failure(ctx.scope, "spex", "the harness restarted", terminal.id)

      assert_receive {:agent_dispatch, id, _ref, message}
      assert id == terminal.id
      assert message =~ "spex"
    end
  end
end
