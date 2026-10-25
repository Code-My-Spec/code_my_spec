defmodule CmsHarness.ARestoreWaitsForTheMcpEndpointTest do
  @moduledoc """
  A harness restarted mid-boot restores its agents before the MCP endpoint they
  dial is listening. Every launch failed `:mcp_session` unreachable and nothing
  tried again, so all twelve agents read running with no process behind them
  until each was restarted by hand (2026-10-25).
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.ChannelClient

  @unreachable {:shutdown,
                {:failed_to_start_child, :mcp_session,
                 {:mcp_session, {:unreachable, %Req.TransportError{reason: :econnrefused}}}}}

  defp launches(answers) do
    {:ok, counter} = Agent.start_link(fn -> answers end)

    fn _agent ->
      Agent.get_and_update(counter, fn [answer | rest] -> {answer, rest} end)
    end
  end

  test "an endpoint not listening yet is waited out" do
    launch = launches([{:error, @unreachable}, {:error, @unreachable}, {:ok, :pid}])
    assert {:ok, :pid} = ChannelClient.restore(%{"agent_id" => "a"}, launch, [0, 0, 0])
  end

  test "it stops waiting when the waits run out, and says why" do
    launch = launches([{:error, @unreachable}, {:error, @unreachable}])
    assert {:error, @unreachable} = ChannelClient.restore(%{"agent_id" => "a"}, launch, [0])
  end

  test "any other failure is answered at once" do
    launch = launches([{:error, :no_credential}, {:ok, :pid}])
    assert {:error, :no_credential} = ChannelClient.restore(%{"agent_id" => "a"}, launch, [0, 0])
  end
end
