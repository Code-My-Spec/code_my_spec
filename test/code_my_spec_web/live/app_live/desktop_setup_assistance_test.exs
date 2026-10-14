defmodule CodeMySpecWeb.AppLive.DesktopSetupAssistanceTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpecWeb.AppLive.DesktopSetupAssistance
  alias CodeMySpecSpex.Fixtures

  setup do
    Fixtures.desktop_setup_main_agent(user_fixture())
  end

  test "an absent main agent is unavailable despite its running record", context do
    assert {:ok, agent, _conversation} = DesktopSetupAssistance.available(context.scope)
    assert agent.id == context.setup_main_agent.id
    :ok = CodeMySpecTest.AgentPresence.absent(agent)
    assert :unavailable = DesktopSetupAssistance.available(context.scope)
  end

  test "a help request rechecks presence before recording or dispatching", context do
    agent = context.setup_main_agent
    assert {:ok, ^agent, conversation} = DesktopSetupAssistance.available(context.scope)
    before_messages = CodeMySpec.Conversations.list_messages(conversation)
    :ok = CodeMySpecTest.AgentPresence.absent(agent)

    assert {:error, :agent_unavailable} =
             DesktopSetupAssistance.request(context.scope, agent.id, %{"steps" => []})

    assert CodeMySpec.Conversations.list_messages(conversation) == before_messages
    refute_received {:agent_dispatch, _, _, _}
  end
end
