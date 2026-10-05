defmodule CodeMySpecWeb.AgentPresenceIsTrackedOnTheCopysChannelTest do
  @moduledoc """
  Phase 1 of `.code_my_spec/plans/agent-liveness-from-presence.md`: the copy's
  harness channel tracks an agent in Presence while the harness says its
  process is up, and the channel dying untracks everything it tracked.
  """

  # The channel runs in its own process and reads the sandbox through it.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.Presence
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup do
    scope = full_scope_fixture()
    root = "/tmp/presence-#{System.unique_integer([:positive])}"
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "copy", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, root)
    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, _reply, channel} =
      UserSocket
      |> socket("user_socket:#{scope.user.id}", %{scope: scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{scope.active_project_id}",
        %{
          "working_copy_id" => copy.id,
          "root" => root,
          "label" => "copy",
          "device" => %{"id" => device_fixture(scope).id}
        }
      )

    {:ok, other} = WorkingCopies.issue(scope, nil, label: "other", device: device_fixture(scope))

    %{
      scope: scope,
      channel: channel,
      topic: Agents.presence_topic(scope.active_project_id),
      agent: agent(scope, copy.id, root),
      sibling: agent(scope, copy.id, root),
      foreign: agent(scope, other.id, "/tmp/elsewhere")
    }
  end

  defp agent(scope, copy_id, root) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: root,
        working_copy_id: copy_id
      })

    agent
  end

  defp say(channel, event, payload) do
    ref = push(channel, event, payload)
    assert_reply ref, :ok, _, 5_000
  end

  defp present(topic), do: topic |> Presence.list() |> Map.keys() |> Enum.sort()

  test "an agent up is tracked, and down untracks it", ctx do
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})
    assert present(ctx.topic) == [ctx.agent.id]

    say(ctx.channel, "agent_down", %{"agent_id" => ctx.agent.id, "reason" => ":normal"})
    assert present(ctx.topic) == []
  end

  test "another copy's agent is not this channel's to track", ctx do
    log = capture_log(fn -> say(ctx.channel, "agent_up", %{"agent_id" => ctx.foreign.id}) end)

    assert present(ctx.topic) == []
    assert log =~ "is not an agent of copy"
  end

  test "the harness's set on join reconciles both ways", ctx do
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})
    say(ctx.channel, "agents_present", %{"agent_ids" => [ctx.sibling.id]})

    assert present(ctx.topic) == [ctx.sibling.id]
  end

  test "the channel dying untracks everything it tracked", ctx do
    say(ctx.channel, "agents_present", %{"agent_ids" => [ctx.agent.id, ctx.sibling.id]})
    :ok = Phoenix.PubSub.subscribe(CodeMySpec.PubSub, ctx.topic)

    Process.unlink(ctx.channel.channel_pid)
    close(ctx.channel)

    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}},
                   5_000

    assert leaves |> Map.keys() |> Enum.sort() == Enum.sort([ctx.agent.id, ctx.sibling.id])
    assert present(ctx.topic) == []
  end

  test "a 60-second report that disagrees with presence is logged", ctx do
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})

    log =
      capture_log(fn ->
        say(ctx.channel, "agents_running", %{"agent_ids" => [ctx.agent.id, ctx.sibling.id]})
      end)

    assert log =~ "disagrees with agents_running"
    assert log =~ ctx.sibling.id
  end
end
