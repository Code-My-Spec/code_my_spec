defmodule CmsHarness.ChannelClientAgentUpTest do
  @moduledoc """
  Issue d12aa283: `Liveness.watch/3` only notifies its subscribers the first
  time a given pid is watched, and a re-attach has only that one chance to
  tell the server this agent is up -- if it is ever missed, the cockpit
  shows the agent `starting` forever. `Channel.report_agent_up/2` is a
  second, direct way to say the same thing, cast straight to this channel
  process the same way `report_turn_event/3` already reaches it.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Project.Transport

  setup do
    Process.put({Transport, :impl}, CmsHarness.Project.Transport.Test)
    Process.put({CmsHarness.Project.Transport.Test, :owner}, self())
    :ok
  end

  defp socket(assigns \\ %{}) do
    %Slipstream.Socket{
      assigns:
        Map.merge(
          %{joined: true, topic: "harness_project:p1", project: %{id: "p1", root: "/tmp/x"}},
          assigns
        )
    }
  end

  test "a joined channel pushes agent_up for the named agent" do
    {:noreply, _socket} = ChannelClient.handle_cast({:agent_up, "agent-1"}, socket())

    assert_receive {:transport_push, "harness_project:p1", "agent_up", payload, _ref}
    assert payload["agent_id"] == "agent-1"
  end

  test "not joined yet is a no-op, not a crash" do
    {:noreply, _socket} =
      ChannelClient.handle_cast({:agent_up, "agent-1"}, socket(%{joined: false}))

    refute_receive {:transport_push, _, _, _, _}, 100
  end
end
