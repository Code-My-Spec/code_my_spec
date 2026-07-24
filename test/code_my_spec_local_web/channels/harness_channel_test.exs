defmodule CodeMySpecLocalWeb.HarnessChannelTest do
  @moduledoc """
  The data-plane harness channel: an `agent_message` from a lane is relayed UP
  toward the server (asserted via the relay PubSub seam, no server needed), and
  the manager's `dispatch` is routed DOWN to the target lane's topic.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentHarness

  @endpoint CodeMySpecLocalWeb.Endpoint

  @external_id "pi:/tmp/harness-test-proj"

  setup do
    scope = full_scope_fixture()

    {:ok, _reply, channel} =
      CodeMySpecLocalWeb.HarnessSocket
      |> socket("harness_socket:#{@external_id}", %{
        scope: scope,
        account_id: scope.active_account_id,
        external_id: @external_id
      })
      |> subscribe_and_join(
        CodeMySpecLocalWeb.HarnessChannel,
        "harness:session:#{@external_id}",
        %{"role" => "coding"}
      )

    %{scope: scope, channel: channel}
  end

  test "agent_message is relayed up toward the server", %{scope: scope, channel: channel} do
    :ok = AgentHarness.subscribe_relay(scope.active_account_id)

    push(channel, "agent_message", %{
      "role" => "coding",
      "kind" => "assistant",
      "text" => "wrote the schema"
    })

    assert_receive {:relay_up, "agent_message", payload}
    assert payload["text"] == "wrote the schema"
    assert payload["role"] == "coding"
    assert payload["external_id"] == @external_id
    assert payload["project_id"] == scope.active_project_id
  end

  test "dispatch is routed to the target lane's topic", %{channel: channel} do
    :ok = AgentHarness.subscribe_lane(@external_id, "qa")

    push(channel, "dispatch", %{"role" => "qa", "prompt" => "verify the story"})

    assert_receive {:to_lane, "user_message", payload}
    assert payload["text"] == "verify the story"
  end
end
