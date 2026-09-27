defmodule CodeMySpecWeb.AReconnectedHarnessLooksForWorkTest do
  @moduledoc """
  A harness reporting what it is running is the moment to ask whether any of it
  should be working.

  `Work.consider_*` is edge-triggered — a graph change, a finished task,
  continuous being switched on — and a restart is none of those. So a promote
  parked the whole fleet until the main agent's cadence came round, twenty
  minutes by default, at exactly the point a restart has just stranded
  reservations and discarded turns. Measured on the math project 2026-09-22:
  three promotes, and after each one every role idle over work that had been
  ready throughout.

  ## Why here and not at application boot

  That is where this was tried first, and it did not work. The boot task runs
  while the agent rows still say whatever the last shutdown left them saying;
  the harness reconnects and re-registers them a moment later, so the sweep
  asked an empty board and woke nobody. Promoted, watched, and confirmed doing
  nothing — coding was eligible the whole time and took a turn the instant it
  was nudged by hand.

  `agents_running` *is* the re-registration, so by the time it returns there is
  something to ask about. The lesson is the one this session kept relearning: a
  fix aimed at the right condition at the wrong instant reads as covered and is
  not.

  ## Once per join

  `agents_running` arrives with every manifest. Admission is guarded but not
  free — `graph_work?/2` is a graph read per idle agent — and a join is the
  event with something to catch.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.DevicesFixtures
  import Phoenix.ChannelTest, except: [push: 3]

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/reconnect-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    {:ok, _reply, socket} =
      UserSocket
      |> socket("reconnect-looks-for-work", %{scope: ctx.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{ctx.scope.active_project_id}",
        %{
          "label" => "the harness that just came back",
          "harness_id" => ctx.scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(ctx.scope).id}
        }
      )

    Map.merge(ctx, %{agent: agent, conversation: conversation, socket: socket})
  end

  # The sweep runs in a Task, so nothing here can read the row the instant the
  # push is replied to. Waiting on the conversation's own broadcast is the
  # deterministic signal — `Conversations.add_message/4` publishes
  # `{:new_message, _}` on the conversation topic — rather than polling the
  # supervisor, which reports an empty child list both before the Task is
  # registered and after it has finished.
  defp report_running(socket, agent) do
    ref = Phoenix.ChannelTest.push(socket, "agents_running", %{"agent_ids" => [agent.id]})
    assert_reply ref, :ok, %{}, 2_000
    :ok
  end

  defp prompts(conversation) do
    conversation
    |> Conversations.list_messages()
    |> Enum.count(&(inspect(&1.content) =~ "Eligible work is available"))
  end

  test "a harness reporting its agents wakes one that has work", ctx do
    :ok = Conversations.subscribe_conversation(ctx.conversation.id)
    report_running(ctx.socket, ctx.agent)

    assert_receive {:new_message, _}, 5_000

    assert prompts(ctx.conversation) >= 1,
           """
           A harness re-registered its agents and nothing asked whether any of
           them should be working.

           This is the moment after a restart when the fleet is idle and its
           work is ready — and nothing else is going to notice until the main
           agent's cadence comes round twenty minutes later.
           """
  end

  test "later reports do not ask again", ctx do
    :ok = Conversations.subscribe_conversation(ctx.conversation.id)
    report_running(ctx.socket, ctx.agent)
    assert_receive {:new_message, _}, 5_000
    after_first = prompts(ctx.conversation)

    report_running(ctx.socket, ctx.agent)
    report_running(ctx.socket, ctx.agent)

    refute_receive {:new_message, _}, 1_000

    assert prompts(ctx.conversation) == after_first,
           """
           Every manifest asked again.

           `agents_running` arrives with each one, and admission is guarded but
           not free: `graph_work?/2` is a graph read per idle agent. The join is
           the event worth catching.
           """
  end
end
