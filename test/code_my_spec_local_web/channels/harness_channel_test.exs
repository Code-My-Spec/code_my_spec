defmodule CodeMySpecLocalWeb.HarnessChannelTest do
  @moduledoc """
  The data-plane harness channel: an `agent_message` from a lane is relayed UP
  toward the server (asserted via the relay PubSub seam, no server needed), and
  the manager's `dispatch` is routed DOWN to the target lane's topic.

  Also what is *running*. `agents_running` had a handler on the server and no
  producer anywhere, so the working-copies page showed every checkout idle no
  matter how many agents were on it. These assert against the same relay seam,
  which is where the absence would have shown up.
  """

  use CodeMySpecTest.DataCase, async: true

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentHarness
  alias CodeMySpecLocalWeb.LaneReporter

  @endpoint CodeMySpecLocalWeb.Endpoint

  @external_id "pi:/tmp/harness-test-proj"

  setup do
    scope = full_scope_fixture()

    # In production `SocketSupervisor` starts one of these per account. Started
    # here because the reporter is what these tests are about — without it the
    # relay seam is silent, which is exactly the state that shipped.
    start_supervised!({LaneReporter, scope: scope})

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

  test "a joined lane is reported to the server as running", %{scope: scope} do
    :ok = AgentHarness.subscribe_relay(scope.active_account_id)

    # The proxy asking on reconnect. Also the cheapest way to observe the set
    # without racing the join that already happened in setup.
    AgentHarness.request_report(scope.active_account_id)

    assert_receive {:relay_up, "agents_running", %{"agents" => agents}}

    assert [%{"working_copy" => "/tmp/harness-test-proj", "role" => "coding", "engine" => "pi"}] =
             agents
  end

  test "a second lane on one copy is reported beside the first, not instead of it",
       %{scope: scope} do
    {:ok, _reply, _qa} =
      CodeMySpecLocalWeb.HarnessSocket
      |> socket("harness_socket:#{@external_id}-qa", %{
        scope: scope,
        account_id: scope.active_account_id,
        external_id: @external_id
      })
      |> subscribe_and_join(
        CodeMySpecLocalWeb.HarnessChannel,
        "harness:session:#{@external_id}",
        %{"role" => "qa"}
      )

    :ok = AgentHarness.subscribe_relay(scope.active_account_id)
    AgentHarness.request_report(scope.active_account_id)

    assert_receive {:relay_up, "agents_running", %{"agents" => agents}}

    assert Enum.sort(Enum.map(agents, & &1["role"])) == ["coding", "qa"],
           "one checkout runs one or more lanes. Reporting a single agent per " <>
             "copy is what made the server's reconcile overwrite one lane with " <>
             "the next, so the page showed one row flickering between them."

    assert Enum.all?(agents, &(&1["working_copy"] == "/tmp/harness-test-proj")),
           "both lanes are on the same checkout and have to say so, or they land " <>
             "on two working copies that do not exist"
  end

  test "a lane declares its engine and provider, and they reach the report", %{scope: scope} do
    {:ok, _reply, _lane} =
      CodeMySpecLocalWeb.HarnessSocket
      |> socket("harness_socket:#{@external_id}-declared", %{
        scope: scope,
        account_id: scope.active_account_id,
        external_id: @external_id
      })
      |> subscribe_and_join(
        CodeMySpecLocalWeb.HarnessChannel,
        "harness:session:#{@external_id}",
        %{"role" => "product", "engine" => "pi", "provider" => "anthropic"}
      )

    :ok = AgentHarness.subscribe_relay(scope.active_account_id)
    AgentHarness.request_report(scope.active_account_id)

    assert_receive {:relay_up, "agents_running", %{"agents" => agents}}
    declared = Enum.find(agents, &(&1["role"] == "product"))

    assert declared["provider"] == "anthropic",
           "the lane is the only thing that knows which subscription it spends, " <>
             "so a report that drops what it declared cannot answer the question " <>
             "the page exists for"

    assert declared["engine"] == "pi"
  end

  test "a lane that declares nothing is still reported, as a Pi lane on an unknown provider",
       %{scope: scope} do
    :ok = AgentHarness.subscribe_relay(scope.active_account_id)
    AgentHarness.request_report(scope.active_account_id)

    assert_receive {:relay_up, "agents_running", %{"agents" => agents}}
    coding = Enum.find(agents, &(&1["role"] == "coding"))

    assert coding["engine"] == "pi" and coding["provider"] == "unknown",
           "identity used to belong to the session, so a lane written before " <>
             "that changed declares only its role. It still has to appear — " <>
             "dropping it would make the page quietly wrong rather than vague."
  end

  test "dispatch is routed to the target lane's topic", %{channel: channel} do
    :ok = AgentHarness.subscribe_lane(@external_id, "qa")

    push(channel, "dispatch", %{"role" => "qa", "prompt" => "verify the story"})

    assert_receive {:to_lane, "user_message", payload}
    assert payload["text"] == "verify the story"
  end
end
