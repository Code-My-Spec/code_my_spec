defmodule CmsHarness.AppInstanceCommitTest do
  @moduledoc """
  048d1f4f: a copy's app is restarted only on a promote, so after its HEAD
  moves an ensure keeps reporting the commit the app was launched on. The
  reply carries HEAD beside it, so that reads as "not restarted", not as a
  stale report.

  `async: false`, as every `app_instance_rig` test: the runner fake is global.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  test "an ensure after HEAD moved reports the launch commit and HEAD, and does not relaunch" do
    app_instance_rig(current_commit: "aaaa1111")

    assert %{"app_commit" => "aaaa1111", "app_head" => "aaaa1111"} =
             push_app_event("ensure_app_running")

    launches = count(:launch)
    FakeAppInstanceRunner.configure(current_commit: "bbbb2222")

    assert %{"app_status" => "serving", "app_commit" => "aaaa1111", "app_head" => "bbbb2222"} =
             push_app_event("ensure_app_running")

    assert count(:launch) == launches
    assert count(:stop_process) == 0
  end

  defp count(name), do: Enum.count(FakeAppInstanceRunner.calls(), &match?({^name, _}, &1))
end
