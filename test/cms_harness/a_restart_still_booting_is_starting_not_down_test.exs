defmodule CmsHarness.ARestartStillBootingIsStartingNotDownTest do
  @moduledoc """
  Issue 8fcce1fb: a restart that recompiled every dep after an alloy bump was
  reported "down, not serving" mid-compile, and /health answered 200 a minute
  later. A restart still booting when its inline wait ends is `starting`,
  watched in the background like a first start.
  """
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  setup do
    rig = app_instance_rig()
    assert %{"app_status" => "serving"} = push_app_event("ensure_app_running")
    # The inline wait is three quarters of this: long enough to probe, short
    # of the boot.
    set_op_timeout(200)
    rig
  end

  test "a restart whose process is alive but not yet serving is reported starting" do
    FakeAppInstanceRunner.put_probe(:down)

    assert %{"status" => "ok", "app_status" => "starting", "app_url" => url} =
             push_app_event("restart_app", 15_000)

    assert url

    FakeAppInstanceRunner.put_probe(:serving)

    assert_receive {:app_status, %{"status" => "serving"}},
                   1_000,
                   "the background watch never reported the restart coming up"
  end
end
