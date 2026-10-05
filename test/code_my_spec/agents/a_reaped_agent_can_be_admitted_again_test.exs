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

  There is no server-side reap any more: liveness is presence, and a crash
  mid-turn is restarted by the harness, which ends the interrupted turn out
  loud (`Engine.Keeper`). What is left here is the way back up.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence

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

    AgentPresence.present(agent)

    %{scope: scope, agent: agent, copy: copy}
  end

  # The way back up, which is where this was actually incomplete.
  #
  # `record_stopped/2` cleared these; `record_started/3`, the reconcile
  # `upsert/3` and `settle_against(.., true)` did not. A row can acquire a
  # `turn_started_at` while already `:stopped` — `record_turn_event(...,
  # "turn_started")` does not check status before writing — and no
  # `turn_ended` is ever coming for it, so the stale timestamp rode into the
  # row's next `:running` life and reported a turn in flight for an agent that
  # was not mid-response. Found by QA on story 1012, `4ce6d903`.
  defp mid_turn(scope, agent) do
    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        turn_started_at: DateTime.utc_now(),
        work_request_id: Ecto.UUID.generate(),
        work_requested_at: DateTime.utc_now()
      })

    agent
  end

  # 73d0d505's counterpart to the mid-turn fixture above: a row that carries
  # a `stopped_reason` from a previous life, which coming back up must not
  # keep saying.
  defp previously_reaped(scope, agent) do
    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        status: :stopped,
        stopped_reason: :reaped
      })

    agent
  end

  defp assert_afresh(agent, path) do
    assert agent.status == :running

    assert is_nil(agent.turn_started_at),
           "#{path} left a turn in flight on an agent whose process has just started"

    assert is_nil(agent.work_request_id),
           "#{path} left a turn reservation on an agent whose process has just started"

    assert is_nil(agent.work_requested_at)
  end

  test "record_started/3 clears a stale turn", ctx do
    stale = ctx.agent |> then(&mid_turn(ctx.scope, &1))

    {:ok, started} = Agents.record_started(ctx.scope, stale, %{agent_id: stale.id})

    assert_afresh(started, "record_started/3")
  end

  test "record_started/3 clears a stale stopped_reason", ctx do
    reaped = ctx.agent |> then(&previously_reaped(ctx.scope, &1))

    {:ok, started} = Agents.record_started(ctx.scope, reaped, %{agent_id: reaped.id})

    assert is_nil(started.stopped_reason),
           "73d0d505: an agent running again must not keep saying why it last " <>
             "stopped — a later, genuinely deliberate stop must not be read as " <>
             "still :reaped from before"
  end

  # The bug behind the bug, found while trying to reach `upsert/3` at all.
  #
  # `adopt/3` finds the existing row with
  # `&1.working_copy_id == copy and &1.role == role`, where the stored side is
  # an `Ecto.Enum` atom and `role/1` reads a string off the wire. `:coding ==
  # "coding"` is false, so the find never matched, every harness report took
  # the insert branch, and a checkout accumulated an agent row per report
  # rather than per lane. Measured in the dev database before the fix: 31
  # main-role rows on one working copy, 17 qa, 12 coding.
  test "a harness report updates the copy's agent rather than adding another", ctx do
    before = Repo.aggregate(Agent, :count)

    {:ok, [adopted]} =
      Agents.record_reported(ctx.scope, [
        %{
          "working_copy_id" => ctx.copy.id,
          "role" => "coding",
          "provider" => "anthropic",
          "working_copy" => ctx.agent.working_copy,
          "os_pid" => 4242
        }
      ])

    assert adopted.id == ctx.agent.id,
           "the report was adopted as a new agent instead of finding the one " <>
             "already on this copy in this role"

    assert Repo.aggregate(Agent, :count) == before,
           "a harness report added an agent row; a checkout then accumulates " <>
             "one per report rather than one per lane"
  end
end
