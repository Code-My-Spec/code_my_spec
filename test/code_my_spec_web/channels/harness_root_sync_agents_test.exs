defmodule CodeMySpecWeb.HarnessRootSyncAgentsTest do
  @moduledoc """
  `report_root/2` corrects `working_copies.root` on any rejoin — a checkout
  that moved, or, for a bare-metal workspace, one whose first boot recorded
  the container path (`/workspace/<app>`) because `Workspaces.instance_root/1`
  had not yet been taught to ask `Runner.Local.root/2` for it.

  That correction alone was not enough. `LaunchRequest.for/1` sends
  `agent.working_copy` verbatim on a restore — a snapshot taken once, when the
  agent's row was created — so an agent started against the wrong root kept
  offering the harness that same wrong root on every later rejoin, and restore
  failed with `:working_copy_missing` against a checkout that had just joined
  under the *correct* one. Reproduced live against a stuck workspace,
  2026-09-21: `working_copies.root` read correctly; `agents.working_copy` on
  its parked `:starting` agent still read `/workspace/listing_manager`.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @stale_root "/workspace/listing_manager"
  @real_root "/Users/johndavenport/.codemyspec/workspaces/cms-workspace-abc123/listing_manager"

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    device = device_fixture(scope)

    %{scope: scope, device: device, topic: "harness_project:#{scope.active_project_id}"}
  end

  defp join_as(scope, topic, payload) do
    UserSocket
    |> socket("harness_root_sync_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, topic, payload)
  end

  defp payload(scope, device, root),
    do: %{
      "label" => "harness at #{root}",
      "harness_id" => scope.active_working_copy_id,
      "root" => root,
      "device" => %{"id" => device.id}
    }

  defp create_agent(scope, copy_id, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{working_copy_id: copy_id, provider: "anthropic", os_pid: nil},
          attrs
        )
      )

    agent
  end

  defp reloaded(id), do: CodeMySpec.Repo.get!(CodeMySpec.Agents.Agent, id)

  # The lease is the channel, so a second join of the same working copy has to
  # wait for the first to be gone rather than merely asked to leave.
  defp leave_and_wait(socket) do
    ref = Process.monitor(socket.channel_pid)
    Phoenix.ChannelTest.leave(socket)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "a parked agent's stale root is corrected when the real one rejoins", %{
    scope: scope,
    device: device,
    topic: topic
  } do
    {:ok, _reply, first} = join_as(scope, topic, payload(scope, device, @stale_root))

    agent =
      create_agent(scope, scope.active_working_copy_id, %{
        working_copy: @stale_root,
        status: :starting
      })

    Process.unlink(first.channel_pid)
    leave_and_wait(first)

    assert {:ok, _reply, _socket} = join_as(scope, topic, payload(scope, device, @real_root))

    assert reloaded(agent.id).working_copy == @real_root,
           "the agent still offers the harness the root its row was created with; " <>
             "a restore against it fails with :working_copy_missing even though this " <>
             "working copy just joined under the correct root"
  end

  test "a stopped agent's recorded root is left alone", %{
    scope: scope,
    device: device,
    topic: topic
  } do
    {:ok, _reply, first} = join_as(scope, topic, payload(scope, device, @stale_root))

    agent =
      create_agent(scope, scope.active_working_copy_id, %{
        working_copy: @stale_root,
        status: :stopped
      })

    Process.unlink(first.channel_pid)
    leave_and_wait(first)

    assert {:ok, _reply, _socket} = join_as(scope, topic, payload(scope, device, @real_root))

    assert reloaded(agent.id).working_copy == @stale_root,
           "a stopped agent is not restored, so correcting its path records an intent " <>
             "nothing will ever act on"
  end

  test "an agent on a different working copy is untouched", %{
    scope: scope,
    device: device,
    topic: topic
  } do
    {:ok, _reply, first} = join_as(scope, topic, payload(scope, device, @stale_root))

    {:ok, other_copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil, label: "a sibling worktree", device: device)

    agent =
      create_agent(scope, other_copy.id, %{
        working_copy: @stale_root,
        status: :starting
      })

    Process.unlink(first.channel_pid)
    leave_and_wait(first)

    assert {:ok, _reply, _socket} = join_as(scope, topic, payload(scope, device, @real_root))

    assert reloaded(agent.id).working_copy == @stale_root,
           "correcting one working copy's root moved an agent that belongs to another"
  end
end
