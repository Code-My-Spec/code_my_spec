defmodule CodeMySpec.Agents.AFailedTurnIsOfferedAgainTest do
  @moduledoc """
  8e9a1d83: a metric_flow agent's whole reply to a request for a help page was
  "Claude Code returned tool_use without any tool calls". It was written as
  the agent speaking, nothing offered the work again, and the request was lost
  — six times from 09-23 to 10-01.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  @failure "Claude Code returned tool_use without any tool calls"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    RecordingAgentTransport.listen(ctx)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "claude-code",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: "/tmp/failed-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    Agents.record_turn_event(ctx.scope, agent.id, %{"kind" => "turn_started"})
    conversation = CodeMySpecSpex.Fixtures.agent_conversation(ctx.scope, agent)
    Conversations.add_message(conversation, :user, "Make me a help page artifact.", "user")

    Map.merge(ctx, %{agent: agent, conversation: conversation})
  end

  defp fail_turn(ctx) do
    Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
      "kind" => "turn_failed",
      "text" => @failure
    })
  end

  test "the agent is told its turn failed, and given the request back", ctx do
    fail_turn(ctx)

    agent_id = ctx.agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, notice}, 2_000
    assert notice =~ @failure
    assert notice =~ "Make me a help page artifact."
  end

  test "the failure is not written as the agent speaking", ctx do
    fail_turn(ctx)
    assert_receive {:agent_dispatch, _, _, _}, 2_000

    assert Conversations.last_message_text(ctx.conversation, :assistant) == nil
    assert Conversations.last_message_text(ctx.conversation, :operator) =~ @failure
  end

  test "a turn that fails on the re-offer is recorded and not sent again", ctx do
    fail_turn(ctx)
    assert_receive {:agent_dispatch, _, _, _}, 2_000

    fail_turn(ctx)

    refute_receive {:agent_dispatch, _, _, _}, 500
    assert Conversations.last_message_text(ctx.conversation, :operator) =~ "failed again"
  end
end
