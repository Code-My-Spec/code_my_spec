defmodule CodeMySpecWeb.AgentPresenceIsTrackedOnTheCopysChannelTest do
  @moduledoc """
  `.code_my_spec/plans/agent-liveness-from-presence.md`: the copy's harness
  channel tracks an agent in `Agents.Presence` while the harness says its
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
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
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
    settle_tasks()
  end

  test "an up for an agent already tracked changes nothing", ctx do
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})

    assert present(ctx.topic) == [ctx.agent.id]
    settle_tasks()
  end

  test "another copy's agent is not this channel's to track", ctx do
    log = capture_log(fn -> say(ctx.channel, "agent_up", %{"agent_id" => ctx.foreign.id}) end)

    assert present(ctx.topic) == []
    assert log =~ "is not an agent of copy"
    settle_tasks()
  end

  test "the harness's set on join reconciles both ways", ctx do
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})
    say(ctx.channel, "agents_present", %{"agent_ids" => [ctx.sibling.id]})

    assert present(ctx.topic) == [ctx.sibling.id]
    settle_tasks()
  end

  # Only a diff with leaves in it is the close's: a join diff for the tracks
  # just made can still be in flight when the subscription starts, and under
  # load it arrived first, with no leaves, and failed the assertion (the
  # promotion gate, 2026-10-05). The channel's keys leave together, with it.
  test "the channel dying untracks everything it tracked", ctx do
    say(ctx.channel, "agents_present", %{"agent_ids" => [ctx.agent.id, ctx.sibling.id]})
    :ok = Phoenix.PubSub.subscribe(CodeMySpec.PubSub, ctx.topic)

    Process.unlink(ctx.channel.channel_pid)
    close(ctx.channel)

    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}}
                   when map_size(leaves) > 0,
                   5_000

    assert leaves |> Map.keys() |> Enum.sort() == Enum.sort([ctx.agent.id, ctx.sibling.id])
    assert present(ctx.topic) == []
    settle_tasks()
  end

  test "a harness from before presence still has its 60-second report answered", ctx do
    say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})
    say(ctx.channel, "agents_running", %{"agent_ids" => [ctx.sibling.id]})

    assert present(ctx.topic) == [ctx.agent.id]
    settle_tasks()
  end

  describe "an agent its harness gave up on" do
    test "stays tracked, marked, and is not running", ctx do
      say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})

      say(ctx.channel, "agent_down", %{
        "agent_id" => ctx.agent.id,
        "reason" => "gave_up: :killed"
      })

      project = ctx.scope.active_project_id
      refute Presence.present?(project, ctx.agent.id)
      assert %{reason: ":killed", at: %DateTime{}} = Presence.gave_up(project, ctx.agent.id)
      assert Agents.lifecycle(agent_row(ctx), Presence.ids(project)) == :gave_up
      settle_tasks()
    end

    test "is running again once it comes up — main restarted it", ctx do
      say(ctx.channel, "agent_down", %{"agent_id" => ctx.agent.id, "reason" => "gave_up: :boom"})
      say(ctx.channel, "agent_up", %{"agent_id" => ctx.agent.id})

      project = ctx.scope.active_project_id
      assert Presence.present?(project, ctx.agent.id)
      assert Presence.gave_up(project, ctx.agent.id) == nil
      settle_tasks()
    end

    test "stays marked across a reconnect, from the join's own report", ctx do
      say(ctx.channel, "agents_present", %{
        "agent_ids" => [ctx.sibling.id],
        "gave_up" => [
          %{"agent_id" => ctx.agent.id, "reason" => ":boom", "at" => "2026-10-05T08:00:00Z"}
        ]
      })

      project = ctx.scope.active_project_id
      assert Presence.ids(project) == MapSet.new([ctx.sibling.id])

      assert %{reason: ":boom", at: ~U[2026-10-05 08:00:00Z]} =
               Presence.gave_up(project, ctx.agent.id)

      settle_tasks()
    end
  end

  # A down and an up each start a task off the channel (`process_ended/3`,
  # `came_up/2`) that reads the database: let them finish while this test still
  # owns its sandbox connection, not after.
  defp settle_tasks do
    for pid <- Task.Supervisor.children(CodeMySpec.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp agent_row(ctx) do
    {:ok, agent} = Agents.fetch_agent(ctx.scope, ctx.agent.id)
    agent
  end
end
