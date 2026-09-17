defmodule CodeMySpec.Agents.ARowClaimingLifeIsSettledByTheProcessTableTest do
  @moduledoc """
  Issue `0c912986`. `agents.status` is written on a clean start and a clean
  stop, so it is a claim about the past, and nothing revised it for an in-BEAM
  agent.

  `record_reported/2` exists to correct exactly this and could never see these
  agents: it is fed by `LaneReporter`, which composes its set from Presence on
  *lane* topics, and an Alloy agent joins no lane. So the one mechanism that
  could contradict a row never applied to the agents whose rows were wrong.

  Measured 2026-09-17: `f8fbe49e` and `93bdde5a` read `starting` for six hours
  with nothing behind them, while `wakeable?/3` accepted `:starting` and kept
  routing work to processes that had never started. Both were restarted by
  hand, which is the remedy this exists to make unnecessary.

  ## The two directions are not the same assertion

  Absent means stopped — the reap, and the half the issue names. Present means
  running, and that half is what makes narrowing `wakeable?/3` to `:running`
  safe: an agent that really did come up is settled from the process table
  within a beat, so the window the exclusion opens is that beat rather than
  forever. Without it, narrowing the predicate would strand every agent that
  was ever briefly `:starting`.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository

  setup do
    scope = full_scope_fixture()
    device = device_fixture(scope)

    {:ok, here} = CodeMySpec.WorkingCopies.issue(scope, nil, label: "this box", device: device)
    {:ok, elsewhere} = CodeMySpec.WorkingCopies.issue(scope, nil, label: "another", device: device)

    %{scope: scope, here: here.id, elsewhere: elsewhere.id}
  end

  defp agent_on(scope, copy_id, status) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy_id: copy_id,
        working_copy: "/tmp/settle-#{System.unique_integer([:positive])}",
        status: status,
        continuous: true
      })

    agent
  end

  defp status_of(scope, id) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, id)
    agent.status
  end

  test "an agent the process table does not hold stops claiming to be running", ctx do
    ghost = agent_on(ctx.scope, ctx.here, :starting)

    :ok = Agents.record_running_on_copy(ctx.scope, ctx.here, [])

    assert status_of(ctx.scope, ghost.id) == :stopped, """
    A row saying `starting` survived a report that named no agents at all.

    That is the whole of `0c912986`: the row goes on claiming life, `wakeable?`
    routes work to it, and the work is held by a process that never existed. Two
    agents sat like this for six hours on 2026-09-17 and had to be restarted by
    hand.
    """
  end

  test "an agent the process table does hold is settled to running", ctx do
    slow = agent_on(ctx.scope, ctx.here, :starting)

    :ok = Agents.record_running_on_copy(ctx.scope, ctx.here, [slow.id])

    assert status_of(ctx.scope, slow.id) == :running, """
    An agent the machine reports as alive was left at `starting`.

    This half is what makes narrowing `wakeable?/3` to `:running` safe. Without
    it, an agent that came up perfectly keeps a status nobody revises and is
    never woken again — trading a stale row that gets work for a live one that
    does not.
    """
  end

  test "a report about one checkout says nothing about another's agents", ctx do
    mine = agent_on(ctx.scope, ctx.here, :running)
    theirs = agent_on(ctx.scope, ctx.elsewhere, :running)

    :ok = Agents.record_running_on_copy(ctx.scope, ctx.here, [mine.id])

    assert status_of(ctx.scope, theirs.id) == :running, """
    An agent on another checkout was reaped by a report that could not have
    known about it.

    The reconcile is per copy precisely because the set is machine-wide: this
    harness serves this checkout, so absence is evidence about its own agents
    and about nobody else's. A harness that reaped across the project would
    stop every agent on every other box the moment one machine reported.
    """
  end

  test "a checkout that was never named is left alone", ctx do
    mine = agent_on(ctx.scope, ctx.here, :starting)

    :ok = Agents.record_running_on_copy(ctx.scope, nil, [])

    assert status_of(ctx.scope, mine.id) == :starting, """
    A report naming no checkout reaped something.

    No report is not a report of absence. A harness that cannot say which copy
    it is speaking for has said nothing, and acting on it would turn a
    misconfigured connection into a fleet-wide stop.
    """
  end
end
