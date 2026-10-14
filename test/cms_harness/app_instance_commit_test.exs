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

  test "a dead app is started on current HEAD rather than its previous revision" do
    app_instance_rig(current_commit: "aaaa1111")
    assert %{"app_status" => "serving"} = push_app_event("ensure_app_running")
    launches = count(:launch)

    FakeAppInstanceRunner.configure(current_commit: "bbbb2222", alive?: false)

    assert %{
             "app_status" => "serving",
             "app_commit" => "bbbb2222",
             "app_head" => "bbbb2222"
           } = push_app_event("ensure_app_running")

    assert count(:launch) == launches + 1
    assert count(:stop_process) == 0
  end

  for health <- [:down, :erroring] do
    test "an alive but #{health} app reports its failed health check and recovery details" do
      app_instance_rig(current_commit: "aaaa1111")
      assert %{"app_status" => "serving"} = push_app_event("ensure_app_running")
      launches = count(:launch)

      FakeAppInstanceRunner.configure(current_commit: "bbbb2222", probe: unquote(health))
      started_at = System.monotonic_time(:millisecond)
      # A generous client-side wait, not a production one: `push_app_event/1`'s
      # own 5s default shares the same shape as the Briefly-backed `TempFile`
      # fixture this suite already hit once (see `TempFile.dir/1`'s own
      # moduledoc) -- a hardcoded client timeout against a single process every
      # `app_instance_rig` test in the suite goes through, so scheduling
      # contention on *that* process under gate load, not anything this test
      # is about, can exhaust it. 15s rules that out without hiding a genuine
      # hang: the app is alive, so a real reply never takes more than one probe.
      result = push_app_event("ensure_app_running", 15_000)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      # An alive app's ensure answers from a single synchronous probe --
      # `wait_for_health`'s own retry-until-serving-or-deadline loop is for a
      # relaunch, and never runs here. A reply this slow means that loop ran
      # anyway (`running?/1` read this alive app as not running), which is a
      # real defect this assertion exists to catch, not a hang to wait out.
      assert elapsed_ms < 2_000,
             "ensure_app_running against an alive app took #{elapsed_ms}ms -- " <>
               "the single-probe path should answer in well under a second; " <>
               "this slow a reply means the relaunch/wait_for_health path ran instead."

      assert result["app_status"] == to_string(unquote(health)),
             "Unexpected app reply: #{inspect(result, limit: :infinity)}\n" <>
               "Runner calls: #{inspect(FakeAppInstanceRunner.calls(), limit: :infinity)}"

      assert result["app_commit"] == "aaaa1111"
      assert result["app_head"] == "bbbb2222"
      assert is_binary(result["app_action_reason"])
      assert result["app_action_reason"] =~ "health"
      assert result["app_action_reason"] =~ "log"
      assert count(:launch) == launches
      assert count(:stop_process) == 0
    end
  end

  defp count(name), do: Enum.count(FakeAppInstanceRunner.calls(), &match?({^name, _}, &1))
end
