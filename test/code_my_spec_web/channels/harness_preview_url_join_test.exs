defmodule CodeMySpecWeb.HarnessPreviewUrlJoinTest do
  @moduledoc """
  Story 968: what the server holds for a project's preview address comes from
  the checkout that serves it, reported on join.

  The same arrangement as `root`, and for the same reason — the web app has no
  disk, so it cannot read `.cms_harness.json` to find out where to point a
  frame. Two places, one fact: the file is the source, the join is the report.

  The refusal is the part worth pinning. Every worktree can run the app, so a
  worktree whose config names a preview is an easy misconfiguration; the server
  must decline to record it *without* dropping the join. Failing the join would
  take a working checkout off the harness entirely — no stop hooks, no sync, no
  agent — over a field nothing else depends on.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @url "https://apricot-tunnel.example.test"

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    %{scope: scope, topic: "harness_project:#{scope.active_project_id}"}
  end

  defp join_as(scope, topic, payload) do
    UserSocket
    |> socket("harness_preview_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, topic, payload)
  end

  defp base(root), do: %{"label" => "harness at #{root}", "root" => root}

  defp fetched(id) do
    {:ok, copy} = WorkingCopies.fetch(id)
    copy
  end

  test "the main checkout's address lands on the server", %{scope: scope, topic: topic} do
    assert {:ok, %{working_copy_id: id}, _socket} =
             join_as(scope, topic, Map.put(base("/workspace/main"), "preview_url", @url))

    assert fetched(id).preview_url == @url,
           "the address is written in the checkout's config and nowhere the web app can " <>
             "read; if the join does not carry it, the panel has nothing to point at"
  end

  test "a worktree does not get to claim it", %{scope: scope, topic: topic} do
    {:ok, %{working_copy_id: main_id}, main} = join_as(scope, topic, base("/workspace/main"))
    Process.unlink(main.channel_pid)
    leave_and_wait(main)

    assert {:ok, %{working_copy_id: id}, _socket} =
             join_as(scope, topic, Map.put(base("/workspace/wt"), "preview_url", @url))

    # Otherwise the refutation below is about the main copy, which would decline
    # for no reason and pass whatever the code did.
    refute id == main_id, "the second root did not become a second working copy"
    refute fetched(main_id).main == false, "the first rooted checkout should be the main one"

    refute fetched(id).preview_url,
           "a second checkout of the project recorded the preview address. Whichever " <>
             "rejoined last would then own it, and the panel would follow the harness " <>
             "that happened to restart."
  end

  test "a worktree that claims it still joins", %{scope: scope, topic: topic} do
    {:ok, _reply, main} = join_as(scope, topic, base("/workspace/main"))
    Process.unlink(main.channel_pid)
    leave_and_wait(main)

    assert {:ok, _reply, _socket} =
             join_as(scope, topic, Map.put(base("/workspace/wt"), "preview_url", @url)),
           "refusing the address is right; refusing the join takes a working checkout " <>
             "off the harness over a field nothing depends on"
  end

  test "a harness that names no address joins and records none", %{scope: scope, topic: topic} do
    assert {:ok, %{working_copy_id: id}, _socket} = join_as(scope, topic, base("/workspace/main"))

    refute fetched(id).preview_url
  end

  # The lease is the channel, so a second join of the same project has to wait
  # for the first to be gone rather than merely asked to leave.
  defp leave_and_wait(socket) do
    ref = Process.monitor(socket.channel_pid)
    Phoenix.ChannelTest.leave(socket)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end
end
