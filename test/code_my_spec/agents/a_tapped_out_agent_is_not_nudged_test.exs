defmodule CodeMySpec.Agents.ATappedOutAgentIsNotNudgedTest do
  @moduledoc """
  An agent that tapped out with no task has asked to leave the loop until a
  person answers: it was nudged 40+ times (fad1a314) and handed the same stop
  decision every turn (070d1bab). A tap-out naming a task holds only that task;
  the agent is offered other work while it waits (story 1080).
  """

  use CodeMySpecSpex.Case, async: false

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Environments
  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    RecordingAgentTransport.listen(ctx)

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/tapped-out-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    on_exit(fn -> :persistent_term.erase({StopDecision, :decision, agent.id}) end)

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    Map.put(ctx, :agent, agent)
  end

  defp tap_out_task(scope, agent) do
    agent =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "bdd_specs_exist",
        started_at: DateTime.utc_now()
      })
      |> Repo.update!()

    [task] = agent.tasks
    {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, task.id, "stuck")
    {Repo.get!(Agent, agent.id), request}
  end

  defp tap_out_whole_agent(scope, agent) do
    {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, nil, "stop")
    request
  end

  defp answered(request) do
    from(p in PermissionRequest, where: p.id == ^request.id)
    |> Repo.update_all(set: [status: "denied", decision: "deny"])
  end

  test "is offered other work while a task's tap-out waits", %{scope: scope, agent: agent} do
    {agent, _request} = tap_out_task(scope, agent)

    refute Waiting.awaiting_tap_out?(agent)
    assert Waiting.reason(scope, agent, :offer) == nil
    assert {:ok, ref} = Work.request_turn_if_runnable(scope, agent, :test)
    assert is_binary(ref)
  end

  test "is not offered a turn while a whole-agent tap-out waits", %{scope: scope, agent: agent} do
    tap_out_whole_agent(scope, agent)

    assert Waiting.awaiting_tap_out?(agent)
    assert Waiting.reason(scope, agent, :offer) == :tap_out

    assert {:ok, :not_runnable} = Work.request_turn_if_runnable(scope, agent, :test)
  end

  test "is offered one again once the tap-out is answered", %{scope: scope, agent: agent} do
    scope |> tap_out_whole_agent(agent) |> answered()

    refute match?({:ok, :not_runnable}, Work.request_turn_if_runnable(scope, agent, :test)),
           "an answered tap-out must not keep the agent out of the loop"
  end

  describe "the stop decision" do
    @impl_path "lib/example_context.ex"

    setup ctx do
      Fixtures.set_analyzer_mode(ctx.scope, :credo, :block_all)

      :ok =
        Environments.write_file(ctx.environment, @impl_path, "defmodule ExampleContext do\nend\n")

      Fixtures.deliver_manifest(ctx.scope)
      Fixtures.record_problem(ctx.scope, "credo", %{file_path: @impl_path})
      Fixtures.fresh_analysis_runs(ctx.scope, ["credo"])
      Fixtures.record_agent_edit(ctx.agent.id, @impl_path)
      :ok
    end

    test "says nothing to an idle agent whose tap-out waits", ctx do
      tap_out_whole_agent(ctx.scope, ctx.agent)

      StopDecision.deliver(ctx.scope, ctx.agent, [])

      refute_receive {:agent_dispatch, _id, _ref, _message}, 500
    end
  end
end
