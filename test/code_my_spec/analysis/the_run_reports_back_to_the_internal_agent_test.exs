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
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.AgentReport
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}

    %{scope: scope, copy: copy}
  end

  defp agent(scope, copy, engine) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: engine,
        role: "coding",
        working_copy: "/tmp/report-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    agent
  end

  defp problem(severity), do: %{severity: severity, source: "spex"}

  test "a run with errors reports back to the agent", ctx do
    agent = agent(ctx.scope, ctx.copy, :alloy)

    AgentReport.deliver(ctx.scope, "spex", [problem(:error), problem(:error)])

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == agent.id
    assert message =~ "spex run finished"
    assert message =~ "2 problems"
    assert message =~ "list_problems"
  end

  # Criterion 3046. A message wakes a process and costs it a turn, and an agent
  # woken to be told its tree is clean has been charged for no information.
  test "a clean run says nothing", ctx do
    agent(ctx.scope, ctx.copy, :alloy)

    AgentReport.deliver(ctx.scope, "spex", [])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  test "warnings alone are not worth waking anyone for", ctx do
    agent(ctx.scope, ctx.copy, :alloy)

    AgentReport.deliver(ctx.scope, "spex", [problem(:warning), problem(:warning)])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  # The other consumer has its own path. Telling it here as well would tell it
  # twice — once now and once on its next tool call.
  test "a Claude Code agent in the same copy is not told here", ctx do
    agent(ctx.scope, ctx.copy, :claude_code)

    AgentReport.deliver(ctx.scope, "spex", [problem(:error)])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  test "every internal agent in the copy is told", ctx do
    one = agent(ctx.scope, ctx.copy, :alloy)
    two = agent(ctx.scope, ctx.copy, :alloy)

    AgentReport.deliver(ctx.scope, "spex", [problem(:error)])

    assert_receive {:agent_dispatch, first, _, _}
    assert_receive {:agent_dispatch, second, _, _}
    assert Enum.sort([first, second]) == Enum.sort([one.id, two.id])
  end

  # It runs inside `Reconciler.reconcile/4`, after the run is recorded. A
  # delivery that cannot land must not make a completed run look incomplete.
  test "a copy with no agents is not an error", ctx do
    assert AgentReport.deliver(ctx.scope, "spex", [problem(:error)]) == :ok
  end

  test "a scope with no working copy is not an error", ctx do
    scope = %{ctx.scope | active_working_copy_id: nil}

    assert AgentReport.deliver(scope, "spex", [problem(:error)]) == :ok
  end
end
