defmodule CodeMySpec.Agents.AReapedContinuousAgentIsRestartedOnReconnectTest do
  @moduledoc """
  73d0d505 — a role a restart killed outright stayed unstaffed forever.

  `consider_copy/4` and `resume_held_tasks/2`, both run on every harness
  reconnect, require `status == :running` — by design, since neither is in
  the business of bringing a dead process back. Nothing else on the
  reconnect path did either, so an agent a shared harness restart actually
  took down (not merely interrupted mid-turn) sat `:stopped, continuous:
  true` until a person noticed and pressed play by hand. Measured: a main
  agent sat that way with the fleet running around it, and four older
  agents on another project's copy the same way.

  The blocker was that nothing distinguished a reap from a deliberate stop
  — `record_stopped/2` was the one path for both, and `continuous` doesn't
  separate them either (an agent stopped on purpose is still `continuous:
  true` on its row). `stopped_reason` is that marker: `Agents.restart_reaped_agents/2`
  only ever touches a row `record_stopped/2` itself marked `:reaped`.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp an_agent(scope, copy, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: "main",
            continuous: true,
            status: :stopped,
            working_copy: "/tmp/reap-restart-#{System.unique_integer([:positive])}",
            working_copy_id: copy.id
          },
          attrs
        )
      )

    agent
  end

  test "a reaped continuous agent is restarted", ctx do
    reaped = an_agent(ctx.scope, ctx.copy, %{stopped_reason: :reaped})

    :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

    restarted = Repo.get(CodeMySpec.Agents.Agent, reaped.id)

    refute restarted.status == :stopped,
           "a role a restart killed outright is still sitting stopped — the whole " <>
             "point of 73d0d505 is that nothing else on the reconnect path reaches it"
  end

  test "a deliberately stopped agent is left alone even though it is still continuous",
       ctx do
    stopped = an_agent(ctx.scope, ctx.copy, %{stopped_reason: :stopped})

    :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

    unchanged = Repo.get(CodeMySpec.Agents.Agent, stopped.id)

    assert unchanged.status == :stopped,
           "continuous: true is not evidence this agent should be running — it means " <>
             "'keep working when running', and a person stopped this one on purpose. " <>
             "Restarting it overrides a decision this sweep has no business overriding."
  end

  test "a row with no stopped_reason (predates the distinction) is left alone", ctx do
    unknown = an_agent(ctx.scope, ctx.copy, %{stopped_reason: nil})

    :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

    unchanged = Repo.get(CodeMySpec.Agents.Agent, unknown.id)

    assert unchanged.status == :stopped,
           "nil means unknown, not reaped — a row from before this distinction " <>
             "existed must not be guessed at either way"
  end

  test "a non-continuous stopped agent is left alone even if it was reaped", ctx do
    one_shot = an_agent(ctx.scope, ctx.copy, %{stopped_reason: :reaped, continuous: false})

    :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

    unchanged = Repo.get(CodeMySpec.Agents.Agent, one_shot.id)

    assert unchanged.status == :stopped,
           "an agent that was never meant to keep working has nothing to resume, " <>
             "regardless of how it stopped"
  end

  test "a reaped agent on a different working copy is left alone", ctx do
    {:ok, other_copy} =
      CodeMySpec.WorkingCopies.issue(ctx.scope, nil,
        label: "a different checkout",
        device: device_fixture(ctx.scope)
      )

    elsewhere = an_agent(ctx.scope, other_copy, %{stopped_reason: :reaped})

    :ok = Agents.restart_reaped_agents(ctx.scope, ctx.copy.id)

    unchanged = Repo.get(CodeMySpec.Agents.Agent, elsewhere.id)

    assert unchanged.status == :stopped,
           "a reconnect on one copy must not restart an agent staffed on another"
  end
end
