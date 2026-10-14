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

  for historical_state <- ["pending", "unknown", "legacy_false"] do
    @historical_state historical_state
    test "historical #{@historical_state} is preserved while current connectivity is live",
         context do
      project = Fixtures.desktop_setup_connected_harness(context.scope)
      captured_at = "2026-01-01T00:00:00Z"
      result = historical_result(@historical_state, project, captured_at)

      snapshot = %{
        "steps" => [],
        "operations" => %{
          "connect" => %{
            "state" => historical_operation_state(@historical_state),
            "finished_at" => historical_finished_at(@historical_state, captured_at),
            "result" => result
          }
        }
      }

      agent_id = context.setup_main_agent.id

      DesktopSetupAssistance.request(context.scope, agent_id, snapshot)
      assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
      [instructions, encoded] = String.split(message, "\n\n", parts: 2)
      payload = Jason.decode!(encoded)
      assert payload["recorded_setup"] == snapshot
      assert payload["current_connection"]["connected"] == true
      assert payload["current_connection"]["connection_state"] == "connected"

      assert {:ok, observed_at, _} =
               DateTime.from_iso8601(payload["current_connection"]["observed_at"])

      assert DateTime.compare(observed_at, DateTime.from_iso8601(captured_at) |> elem(1)) == :gt
      assert instructions =~ "recorded_setup is historical"
      assert instructions =~ "connect operation's finished_at for older records"

      assert instructions =~
               "historical connected=false is not evidence of a current connection failure"

      assert instructions =~
               "pending means the observation window expired, not that connection failed"

      assert instructions =~
               "Do not rerun completed setup checks or change their recorded outcomes"
    end
  end

  test "another project's recorded connection yields unknown current connectivity", context do
    project = Fixtures.desktop_setup_connected_harness(context.scope)

    snapshot = %{
      "steps" => [],
      "operations" => %{
        "connect" => %{
          "state" => "done",
          "finished_at" => "2026-01-01T00:00:00Z",
          "result" => %{
            "id" => Ecto.UUID.generate(),
            "root" => project.root,
            "connected" => false
          }
        }
      }
    }

    agent_id = context.setup_main_agent.id
    DesktopSetupAssistance.request(context.scope, agent_id, snapshot)
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 5_000
    [instructions, encoded] = String.split(message, "\n\n", parts: 2)
    payload = Jason.decode!(encoded)
    assert payload["recorded_setup"] == snapshot
    assert payload["current_connection"]["connection_state"] == "unknown"
    refute Map.has_key?(payload["current_connection"], "connected")
    assert {:ok, _, _} = DateTime.from_iso8601(payload["current_connection"]["observed_at"])
    assert instructions =~ "unknown means it could not be checked for this project"

    assert instructions =~
             "historical connected=false is not evidence of a current connection failure"
  end

  defp historical_operation_state("pending"), do: "pending"
  defp historical_operation_state(_state), do: "done"
  defp historical_finished_at("pending", _captured_at), do: nil
  defp historical_finished_at(_state, captured_at), do: captured_at

  defp historical_result("legacy_false", project, _captured_at) do
    %{"id" => project.id, "root" => project.root, "connected" => false}
  end

  defp historical_result(state, project, captured_at) do
    %{
      "id" => project.id,
      "root" => project.root,
      "connected" => false,
      "connection_state" => state,
      "observed_at" => captured_at
    }
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
