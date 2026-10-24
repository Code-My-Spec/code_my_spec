defmodule CmsHarness.AnAppReportedOnJoinIsTheOneRunningTest do
  @moduledoc """
  Issue 00bd7d4a, story 1046: `working_copies.app_commit` can lag the running app
  after a restart whose result never reaches the server.

  A restart's result reaches the server as a reply (`restart_app_result`) and,
  when the start's own background watch resolves late, as a push. Both are
  messages on the channel. A harness that restarts mid-reply, a socket that
  drops, or the promote lost-ack path leaves the last write in the server
  holding a commit the app is not running: metric_flow's main copy reported
  `app_commit` c3eb20b while the harness's own `state.json` and git HEAD were
  59dc451.

  The durable answer is written down on the harness's own disk, in the
  `AppInstance` `state.json`, and the server can ask for it at the one moment a
  harness is guaranteed to be talking to it: on join. An older server ignores an
  unknown join field, so the rollout order does not matter — the same reasoning
  `active_runs` is built on.

  What this does not change: the reply and push paths stay as they are. This is
  the convergence the issue asks for, not a replacement for them.
  """

  # Sync: `app_instance_rig` sets application env.
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarness.AppInstance
  alias CmsHarnessTest.FakeAppInstanceRunner

  test "a harness reports the app its own state.json names, on join" do
    ctx = app_instance_rig(current_commit: "aaaa1111")
    assert %{"app_status" => "serving"} = push_app_event("ensure_app_running")

    # HEAD moves and nothing restarts the app: the server would otherwise keep
    # reporting whatever the last reply said.
    FakeAppInstanceRunner.configure(current_commit: "bbbb2222")

    assert %{"commit" => "aaaa1111", "status" => "serving"} =
             AppInstance.reported(instance(ctx.root))
  end

  test "a copy whose app never ran reports nothing rather than a guess" do
    ctx = app_instance_rig()

    assert AppInstance.reported(instance(ctx.root)) == nil
  end

  test "a stopped app reports itself down, not its last commit" do
    ctx = app_instance_rig(current_commit: "aaaa1111")
    assert %{"app_status" => "serving"} = push_app_event("ensure_app_running")
    assert %{"status" => "ok"} = push_app_event("stop_app")

    assert %{"commit" => "aaaa1111", "status" => "down"} =
             AppInstance.reported(instance(ctx.root))
  end
end
