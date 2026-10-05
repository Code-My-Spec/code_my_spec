defmodule CodeMySpec.Agents.ATaskClosedEarlierInARunIsNotADeclineTest do
  @moduledoc """
  35e80d6d — the coder that closed a task was damped as having refused work.

  metric_flow, 2026-09-30: three chats queued behind each other on the coder.
  Turn B closed `story_issues_resolved` at 08:49:08; turn C, queued behind it,
  started at ~08:49:13 and ended at 08:49:23. The harness only announces the end
  of a *run* (`announce_turn_end` stays quiet while the queue is non-empty), but
  it announces every start — so `turn_started_at` held C's start, the task B
  closed predated it, and `Work.record_decline/3` charged the run with declining
  its offer. That offer had already been declined five times at 08:28, so the
  damper held the agent for ten minutes and the fleet idled until an unrelated
  issue woke it at 09:04.

  A run of queued turns is one run: its start is the first turn's.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    # Real coding work on the board, so there is an offer to be charged with.
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/run-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    on_exit(fn ->
      for tag <- [:decision, :continuing],
          do: :persistent_term.erase({CodeMySpec.Agents.StopDecision, tag, agent.id})
    end)

    Map.put(ctx, :agent, agent)
  end

  defp reload(scope, agent) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)
    fresh
  end

  defp turn_started(scope, agent),
    do: Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_started"})

  defp close_a_task(scope, agent) do
    now = DateTime.utc_now()

    {:ok, _} =
      scope
      |> reload(agent)
      |> CodeMySpec.Agents.Agent.add_task(%{
        requirement_name: "story_issues_resolved",
        status: :completed,
        started_at: DateTime.add(now, -60, :second),
        completed_at: now
      })
      |> CodeMySpec.Repo.update()
  end

  # Turn B, already under way: started two minutes ago, and closed its task.
  defp run_under_way(scope, agent) do
    started = DateTime.add(DateTime.utc_now(), -120, :second)

    {:ok, _} =
      AgentsRepository.update_agent(scope, reload(scope, agent), %{turn_started_at: started})
  end

  test "a task closed by an earlier turn of the same run is not a decline", ctx do
    run_under_way(ctx.scope, ctx.agent)
    close_a_task(ctx.scope, ctx.agent)

    # Turn C, queued behind it. Its end is the only one announced.
    turn_started(ctx.scope, ctx.agent)
    :ok = Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "turn_ended"})

    agent = reload(ctx.scope, ctx.agent)

    assert is_nil(agent.declined_offer),
           "the run closed a task; charging it with declining the next offer is what " <>
             "damped the coder for ten minutes (declined_offer_count=" <>
             "#{inspect(agent.declined_offer_count)})"
  end
end
