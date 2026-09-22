defmodule CodeMySpec.MainAgent.ARestartDoesNotCostAnIntervalTest do
  @moduledoc """
  Coming back up looks at the fleet, rather than waiting a full interval to.

  `Cadence.init/1` schedules the first tick one interval out — twenty minutes by
  default — and the recovery sweep rides on that tick. So a boot parked every
  continuous agent for twenty minutes, which is the worst moment to be blind: a
  restart is exactly when turns get interrupted and reservations get stranded,
  and the fleet comes back with work waiting and nothing looking for it.

  Measured 2026-09-22 on the math project: two promotes, and after each one four
  roles sat idle over a requirement that was ready the whole time. Nothing was
  wrong with the graph or the agents — `Work.consider_*` is edge-triggered on a
  graph change, a finished task, or continuous being switched on, and a restart
  is none of those.

  The sweep is `Work.consider_project/2` alone rather than `check_in/1`: no
  digest, and so no model call spent looking at a fleet that may have nothing to
  do. Admission is guarded on eligibility, so a boot with an empty board wakes
  nobody — the second test.

  ## Observed through the transcript, and synchronised without sleeping

  `Work` records the turn prompt against the agent's conversation *before*
  dispatching it, so the message lands whether or not a machine is behind the
  agent — which in a test there is not.

  `init/1` sends `:consider_on_boot` to itself, so it is already in the mailbox
  when `ensure_running/1` returns. One `GenServer.call` behind it is enough:
  mailboxes are FIFO, so a reply to the call proves the sweep was handled. No
  polling, and nothing to be flaky about.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.MainAgent.Cadence
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Staffed *after* the graph has settled, and that ordering is the test.
  #
  # `GraphWatcher.settle/1` fires `Work.consider_project(.., :graph_changed)`,
  # which admits any agent already standing there with work — so an agent
  # created before the fixture runs gets its turn from the graph event and the
  # boot sweep proves nothing. The first version of this passed with the sweep
  # deleted. An agent that arrives afterwards is the real case anyway: the
  # restart puts the agents back, and nothing about the graph has changed.
  defp staffed(ctx) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/boot-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    conversation
  end

  defp swept(scope) do
    {:ok, _pid} = Cadence.ensure_running(scope)
    # Flushes `:consider_on_boot` — see the moduledoc.
    _ = Cadence.last_check(scope)
    :ok
  end

  defp admitted?(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.any?(&(inspect(&1.content) =~ "Eligible work is available"))
  end

  test "starting the cadence looks for work straight away", ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)
    conversation = staffed(ctx)

    :ok = swept(ctx.scope)

    assert admitted?(conversation),
           """
           A boot left an agent with work on the board waiting for the first tick.

           The recovery sweep rides on a timer set one full interval out, so
           until it fires nothing is looking at the fleet — and a restart is
           when there is most to look at.
           """
  end

  test "a boot with nothing to do wakes nobody", ctx do
    conversation = staffed(ctx)

    :ok = swept(ctx.scope)

    refute admitted?(conversation),
           """
           A boot admitted a turn against an empty board.

           The sweep is guarded on eligibility for the same reason the cadence
           stands down when the main agent taps out: a model call to look at a
           fleet with nothing to do is spend with nothing behind it.
           """
  end
end
