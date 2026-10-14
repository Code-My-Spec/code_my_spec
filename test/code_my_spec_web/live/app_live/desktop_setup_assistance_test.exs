defmodule CodeMySpecWeb.AppLive.DesktopSetupAssistanceTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpecWeb.AppLive.DesktopSetupAssistance
  alias CodeMySpecSpex.Fixtures

  setup do
    Fixtures.desktop_setup_main_agent(user_fixture())
  end

  test "help preserves historical connection evidence and separates current observations",
       context do
    agent_id = context.setup_main_agent.id
    captured_at = "2026-01-01T00:00:00Z"

    snapshot = %{
      "steps" => [%{"key" => "cms", "state" => "done", "finished_at" => captured_at}],
      "operations" => %{
        "connect" => %{
          "state" => "done",
          "finished_at" => captured_at,
          "result" => %{
            "id" => context.scope.active_project_id,
            "root" => "/nonexistent/desktop-help-#{Ecto.UUID.generate()}",
            "connected" => false
          }
        }
      }
    }

    DesktopSetupAssistance.request(context.scope, agent_id, snapshot)
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    [_instructions, encoded] = String.split(message, "\n\n", parts: 2)
    payload = Jason.decode!(encoded)
    assert payload["recorded_setup"] == snapshot
    assert payload["main_agent_present"] == true
    assert payload["current_connection"]["connected"] == false
    assert {:ok, _, _} = DateTime.from_iso8601(payload["current_connection"]["observed_at"])
    assert message =~ "historical connected=false is not evidence of a current connection failure"
    assert message =~ "Do not invent failures when checks passed"
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
