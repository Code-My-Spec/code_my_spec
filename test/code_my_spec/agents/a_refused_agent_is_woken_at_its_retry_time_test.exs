defmodule CodeMySpec.Agents.ARefusedAgentIsWokenAtItsRetryTimeTest do
  @moduledoc """
  A turn end the provider refused is held (`Waiting`), so the retry time it
  named is the wake: the held turn-end delivery runs then. Without it an agent
  holding a task sat silent past its retry time with nothing to wake it.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.RefusalWake
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    # The wake runs off a timer, in its own process.
    Sandbox.mode(Repo, {:shared, self()})

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/refused-wake-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "bdd_specs_passing",
        started_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })
      |> Repo.update()

    on_exit(fn -> :persistent_term.erase({StopDecision, :continuing, agent.id}) end)

    Map.put(ctx, :agent, agent)
  end

  # An hour out: the real timer never fires during the run. Time passing is
  # simulated by moving `provider_retry_at` back and calling the wake directly.
  defp refused(seconds), do: "Error: 429 rate limit exceeded, try again in #{seconds} seconds"

  defp turn(scope, agent, events) do
    Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_started"})
    Enum.each(events, &Agents.record_turn_event(scope, agent.id, &1))
    Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_ended"})
  end

  defp refused_turn(scope, agent, seconds),
    do: turn(scope, agent, [%{"kind" => "turn_failed", "text" => refused(seconds)}])

  # The schedule cast has landed once a call returns.
  defp scheduled(agent_id) do
    :sys.get_state(RefusalWake) |> Map.get(agent_id) |> then(&(&1 && elem(&1, 1)))
  end

  defp reload(scope, agent) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, agent.id)
    agent
  end

  defp retry_time_passes(scope, agent) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    {:ok, _} = AgentsRepository.update_agent(scope, agent, %{provider_retry_at: past})
    past
  end

  test "a task-holding agent refused until T is scheduled for T and delivered its turn then",
       ctx do
    refused_turn(ctx.scope, ctx.agent, 3600)
    agent = reload(ctx.scope, ctx.agent)

    assert scheduled(agent.id) == agent.provider_retry_at
    refute_received {:agent_dispatch, _, _ref, _message}

    assert {:later, _} = RefusalWake.due(ctx.scope, agent.id, agent.provider_retry_at)

    past = retry_time_passes(ctx.scope, agent)
    assert {:due, _} = RefusalWake.due(ctx.scope, agent.id, past)
    RefusalWake.wake(ctx.scope, agent.id, past)

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}
    assert message =~ "loop is still running"
  end

  test "a later refusal moves the wake to its own retry time", ctx do
    refused_turn(ctx.scope, ctx.agent, 3600)
    first = reload(ctx.scope, ctx.agent).provider_retry_at
    refused_turn(ctx.scope, ctx.agent, 7200)
    second = reload(ctx.scope, ctx.agent).provider_retry_at

    assert DateTime.compare(second, first) == :gt
    assert scheduled(ctx.agent.id) == second

    # The replaced wake finds a different refusal standing and does nothing.
    assert RefusalWake.due(ctx.scope, ctx.agent.id, first) == :moved_on
  end

  test "a turn that succeeds before T makes the wake a no-op", ctx do
    refused_turn(ctx.scope, ctx.agent, 3600)
    retry_at = reload(ctx.scope, ctx.agent).provider_retry_at
    turn(ctx.scope, ctx.agent, [])

    agent_id = ctx.agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, _ordinary_turn_end}
    assert reload(ctx.scope, ctx.agent).provider_retry_at == nil

    assert RefusalWake.due(ctx.scope, agent_id, retry_at) == :moved_on
  end

  # The timer lives in memory; a reconnect after a restart re-arms it.
  test "a reconnect re-arms the wake a restart dropped", ctx do
    retry_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, _refused} =
      AgentsRepository.update_agent(ctx.scope, ctx.agent, %{
        provider_refusal: "rate limit exceeded",
        provider_refused_at: DateTime.utc_now(),
        provider_retry_at: retry_at
      })

    :ok = RefusalWake.rearm(ctx.scope, ctx.agent.working_copy_id)

    assert DateTime.compare(scheduled(ctx.agent.id), retry_at) == :eq
  end

  # Unchanged: nothing holds its turn end, and nothing is scheduled after it.
  test "a refusal naming no time schedules nothing", ctx do
    turn(ctx.scope, ctx.agent, [
      %{"kind" => "turn_failed", "text" => "Error: Invalid API key · Please run /login"}
    ])

    agent_id = ctx.agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, _ordinary_turn_end}
    assert scheduled(agent_id) == nil
  end
end
