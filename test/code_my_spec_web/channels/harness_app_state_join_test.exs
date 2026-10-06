defmodule CodeMySpecWeb.HarnessAppStateJoinTest do
  @moduledoc """
  Issue 00bd7d4a, story 1046: `working_copies.app_commit` converges on what the
  harness's own `state.json` says after any restart.

  A restart's result reaches the server as a channel reply or push, and a
  harness that restarted mid-reply â or whose socket dropped and reconnected â
  leaves the last write naming a commit the app is not serving. metric_flow's
  main copy reported `app_commit` c3eb20b while the harness's own `state.json`
  and git HEAD were 59dc451. Promotion now keys on commits, so a stale row is
  not cosmetic.

  `CmsHarness.AnAppReportedOnJoinIsTheOneRunningTest` covers the harness reading
  its own `state.json`. This covers that value reaching the row through a join.

  Worth its own test rather than an assertion inside the join test: the failure
  it guards is a row that keeps a value, and a join test that only checks the
  reply would report success.
  """

  # Not async: the channel takes the project's advisory lock on join.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    scope = full_scope_fixture()
    %{scope: scope, topic: "harness_project:#{scope.active_project_id}"}
  end

  defp join_reporting(scope, topic, extra) do
    payload =
      Map.merge(
        %{
          "label" => "the harness at /workspace/app",
          "harness_id" => scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(scope).id}
        },
        extra
      )

    socket(UserSocket, "app_state_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, topic, payload)
  end

  defp copy(scope) do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    copy
  end

  test "a join records the app the harness says it is running", ctx do
    {:ok, _, _} =
      join_reporting(ctx.scope, ctx.topic, %{
        "app" => %{"status" => "serving", "commit" => "aaaa1111", "url" => "http://127.0.0.1:4000"}
      })

    recorded = copy(ctx.scope)

    assert recorded.app_commit == "aaaa1111"
    assert recorded.app_status == "serving"
  end

  test "a later join corrects a commit the server still held", ctx do
    {:ok, _, first} =
      join_reporting(ctx.scope, ctx.topic, %{
        "app" => %{"status" => "serving", "commit" => "c3eb20b", "url" => "http://127.0.0.1:4000"}
      })

    assert copy(ctx.scope).app_commit == "c3eb20b"
    leave_and_wait(first)

    # The restart's result never reached the server; the harness comes back and
    # says what it is actually running. This is the correction 00bd7d4a asks for.
    {:ok, _, _} =
      join_reporting(ctx.scope, ctx.topic, %{
        "app" => %{"status" => "serving", "commit" => "59dc451", "url" => "http://127.0.0.1:4000"}
      })

    assert copy(ctx.scope).app_commit == "59dc451",
           "the server kept the commit the app was not running, which is the state " <>
             "promotion now keys on"
  end

  test "a harness that says nothing about its app leaves the row alone", ctx do
    {:ok, _, first} =
      join_reporting(ctx.scope, ctx.topic, %{
        "app" => %{"status" => "serving", "commit" => "aaaa1111"}
      })

    leave_and_wait(first)

    assert {:ok, _, _} = join_reporting(ctx.scope, ctx.topic, %{})

    assert copy(ctx.scope).app_commit == "aaaa1111",
           "an older harness sends nothing, and 'not reported' is not 'the app is down'. " <>
             "Clearing here would take a serving copy off the graph for a field it does not know."
  end

  test "a harness reporting a down app clears its address", ctx do
    {:ok, _, first} =
      join_reporting(ctx.scope, ctx.topic, %{
        "app" => %{"status" => "serving", "commit" => "aaaa1111", "url" => "http://127.0.0.1:4000"}
      })

    leave_and_wait(first)

    {:ok, _, _} =
      join_reporting(ctx.scope, ctx.topic, %{"app" => %{"status" => "down", "commit" => "aaaa1111"}})

    assert copy(ctx.scope).app_status == "down"
    assert copy(ctx.scope).app_url == nil
  end

  # The lease is the channel, so a second join of the same working copy has to
  # wait for the first to be gone rather than merely asked to leave.
  defp leave_and_wait(socket) do
    Process.unlink(socket.channel_pid)
    ref = Process.monitor(socket.channel_pid)
    Phoenix.ChannelTest.leave(socket)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end
end
