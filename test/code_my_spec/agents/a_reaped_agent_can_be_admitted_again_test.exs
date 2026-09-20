defmodule CodeMySpec.Agents.AReapedAgentCanBeAdmittedAgainTest do
  @moduledoc """
  Reaping an agent has to clear what only a live process could have meant.

  `turn_started_at` and `work_request_id` both say "something is happening
  right now" — a turn in flight, a turn reserved and about to be dispatched.
  Neither can be true of an agent with no process behind it, and
  `Work.runnable_state?/1` requires both to be nil. So a reaped agent that
  comes back carrying either one is permanently un-admittable, and nothing
  would ever clear them, because clearing them is what reaping is for.

  Found by QA on story 1004 on 2026-09-20, chasing why a fixture agent could
  not be offered a turn.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/reaped-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent, copy: copy}
  end

  test "stopping clears the turn and the reservation", ctx do
    {:ok, mid_turn} =
      AgentsRepository.update_agent(ctx.scope, ctx.agent, %{
        turn_started_at: DateTime.utc_now(),
        work_request_id: Ecto.UUID.generate(),
        work_requested_at: DateTime.utc_now()
      })

    assert mid_turn.turn_started_at
    assert mid_turn.work_request_id

    # What the harness reports when it comes back holding nothing: this copy is
    # running no agents, so the row claiming to be mid-turn is reaped.
    :ok = Agents.record_running_on_copy(ctx.scope, ctx.copy.id, [])

    reaped = Repo.get(Agent, ctx.agent.id)

    assert reaped.status == :stopped

    assert is_nil(reaped.turn_started_at),
           "a stopped agent is still holding a turn it cannot be running, so it " <>
             "can never be offered another one"

    assert is_nil(reaped.work_request_id),
           "a stopped agent is still holding a turn reservation, so it can never " <>
             "be offered another one"

    assert is_nil(reaped.work_requested_at)
  end
end
