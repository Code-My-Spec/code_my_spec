defmodule CodeMySpec.Agents.AProviderRefusalIsAgentStateTest do
  @moduledoc """
  A turn the provider refused is recorded on the agent, and a later turn that
  is not refused clears it.

  Issue 044599cc, measured 2026-09-24: an exhausted openai-codex account left
  all three agents reading `running` for over two hours. The provider said
  exactly what was wrong and when it would stop — "try again at Sep 30th, 2026
  11:20 PM" — and none of it reached any state an operator or `check_in` read.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.RecordingAgentTransport

  @usage_limit """
  codex exec failed with status 1: OpenAI Codex v0.156.1 — ERROR: You've hit your usage limit. \
  Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at \
  Sep 30th, 2026 11:20 PM.\
  """

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "openai-codex",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/refused-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    Map.put(ctx, :agent, agent)
  end

  defp reload(scope, agent) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)
    fresh
  end

  defp turn(scope, agent, events) do
    Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_started"})
    Enum.each(events, &Agents.record_turn_event(scope, agent.id, &1))
    Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_ended"})
    reload(scope, agent)
  end

  test "a usage-limit failure is recorded with its reason and retry time", ctx do
    agent = turn(ctx.scope, ctx.agent, [%{"kind" => "turn_failed", "text" => @usage_limit}])

    assert agent.provider_refusal =~ "You've hit your usage limit"
    refute agent.provider_refusal =~ "OpenAI Codex v0.156.1"
    assert agent.provider_retry_at == ~U[2026-09-30 23:20:00.000000Z]
    assert %DateTime{} = agent.provider_refused_at
  end

  test "a refusal naming no time keeps the text and no retry", ctx do
    text = "claude-code exited 1 — Error: Invalid API key · Please run /login"
    agent = turn(ctx.scope, ctx.agent, [%{"kind" => "turn_failed", "text" => text}])

    assert agent.provider_refusal == "Invalid API key · Please run /login"
    assert agent.provider_retry_at == nil
  end

  test "a failure that is not a refusal records nothing", ctx do
    text = "codex exec failed with status 139: OpenAI Codex v0.156.1"
    agent = turn(ctx.scope, ctx.agent, [%{"kind" => "turn_failed", "text" => text}])

    assert agent.provider_refusal == nil
  end

  test "a later turn that is not refused clears it", ctx do
    refused = turn(ctx.scope, ctx.agent, [%{"kind" => "turn_failed", "text" => @usage_limit}])
    assert refused.provider_refusal

    cleared = turn(ctx.scope, refused, [%{"kind" => "message", "text" => "done"}])

    assert cleared.provider_refusal == nil
    assert cleared.provider_refused_at == nil
    assert cleared.provider_retry_at == nil
  end

  test "an agent refused until later is not offered work until then", ctx do
    refused = turn(ctx.scope, ctx.agent, [%{"kind" => "turn_failed", "text" => @usage_limit}])

    assert Work.request_turn_if_runnable(ctx.scope, refused, :test) == {:ok, :not_runnable}

    {:ok, past} =
      AgentsRepository.update_agent(ctx.scope, refused, %{
        provider_retry_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    refute Work.request_turn_if_runnable(ctx.scope, past, :test) == {:ok, :not_runnable}
  end
end
