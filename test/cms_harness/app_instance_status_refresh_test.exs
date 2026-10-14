defmodule CmsHarness.AppInstanceStatusRefreshTest do
  @moduledoc """
  Story 1117 QA: a copy's app recorded "down" while it was serving, and
  `share_copy_app` refused until an `ensure_app_running` re-read it. The idle
  tick now re-reads a running app and reports a change.
  """

  # Sync: `app_instance_rig` sets application env.
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarness.AppInstance
  alias CmsHarnessTest.FakeAppInstanceRunner

  test "the tick reports a running app whose status changed since it was last asked" do
    %{root: root} = app_instance_rig(database_exists?: true)
    assert %{"status" => "ok", "app_status" => "serving"} = push_app_event("ensure_app_running")

    FakeAppInstanceRunner.put_probe(:erroring)
    pid = GenServer.whereis(AppInstance.via(root))
    # Requests reaching the app move its log; an idle copy would be stopped.
    log = :sys.get_state(pid).log_path
    File.mkdir_p!(Path.dirname(log))
    File.touch!(log)
    send(pid, :timeout)

    assert :sys.get_state(pid).status == "erroring"
    assert_receive {:app_status, %{"status" => "erroring"}}, 1_000
  end
end
