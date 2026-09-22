defmodule CodeMySpec.Notifications.DenyingATapOutPutsTheAgentBackToWorkTest do
  @moduledoc """
  A person answering a gate is the moment to ask whether the agent can work.

  Denying a tap-out leaves the agent in the loop, and until this existed nothing
  noticed. `Work.consider_*` is edge-triggered on a graph change, a finished
  task, or continuous being switched on, and a person answering a gate is none
  of those — so an agent that had work all along went on waiting for a change
  that was not coming.

  Measured on the math project 2026-09-22: coding's tap-out was denied and it
  sat eligible and idle for eight minutes afterwards, with the rest of the fleet
  queued behind its requirement. The whole reason to deny rather than allow is
  that there is work to do.

  `allow` is deliberately not woken: it takes the agent out of the loop, which
  is what it asked for, and waking it would answer the opposite question.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Staffed after the graph settles, so the only thing that can admit a turn is
  # the decision under test. `GraphWatcher.settle/1` fires its own
  # `consider_project`, and an agent standing there first is woken by that.
  defp staffed_with_work(ctx) do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/denied-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    {:ok, request} =
      Notifications.request_agent_tap_out(ctx.scope, agent.id, nil, "nothing to do")

    {agent, conversation, request}
  end

  defp told?(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.any?(&(inspect(&1.content) =~ "was declined"))
  end

  defp admitted?(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.any?(&(inspect(&1.content) =~ "Eligible work is available"))
  end

  test "denying it offers the agent a turn", ctx do
    {_agent, conversation, request} = staffed_with_work(ctx)

    :ok = Conversations.subscribe_conversation(conversation.id)

    {:ok, _} = Notifications.resolve_permission_request(request.id, "deny")

    # Two messages land: the notice, written before the wake, and the work
    # prompt the wake produces. Waiting for one would race whichever is second.
    assert_receive {:new_message, _}, 5_000
    assert_receive {:new_message, _}, 5_000

    assert told?(conversation),
           """
           The agent was woken without being told its request was answered.

           It reads its own transcript, where the last thing it said is that it
           is waiting — so it concludes it still is, stops, and does the same on
           the next wake. That is a spin, and the wake is what causes it.
           """

    assert admitted?(conversation),
           """
           A denied tap-out left the agent in the loop and asleep.

           Denying it means there is work to do — that is the whole reason to
           deny rather than allow — and nothing else is coming to notice.
           """
  end

  test "allowing it does not", ctx do
    {_agent, conversation, request} = staffed_with_work(ctx)

    :ok = Conversations.subscribe_conversation(conversation.id)

    {:ok, _} = Notifications.resolve_permission_request(request.id, "allow")

    refute_receive {:new_message, _}, 1_000

    refute told?(conversation),
           "an allowed tap-out was told its request was declined"

    refute admitted?(conversation),
           """
           An allowed tap-out was handed a turn.

           It asked to leave the loop and was told yes; waking it answers the
           opposite question.
           """
  end
end
