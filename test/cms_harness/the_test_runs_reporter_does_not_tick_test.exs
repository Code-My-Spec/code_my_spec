defmodule CmsHarness.TheTestRunsReporterDoesNotTickTest do
  @moduledoc """
  e258f257. The run-wide `CmsHarness.Supervisor` that `test_helper.exs` starts
  carries a `WorkingCopyReporter`, and its announce drives the endpoint in the
  reporter's own process. A tick that landed while a test held a credential
  queried the sandbox with no owner, crashed, crashed again on its immediate
  restart report, and took the supervisor — linked to the test runner — and the
  whole suite down with no summary. Under `mix test` it only reports when told.
  """
  use ExUnit.Case, async: false

  test "it schedules nothing of its own" do
    assert %{heartbeat: :never} = :sys.get_state(CmsHarness.WorkingCopyReporter)
  end

  test "a report that crashes does not loop and does not take the harness tree down" do
    oauth_dir = CodeMySpecTest.HarnessOAuthFixture.isolate()

    CodeMySpecTest.HarnessOAuthFixture.seed(
      oauth_dir,
      CmsHarness.Config.server_url(),
      "e258f257"
    )

    supervisor = Process.whereis(CmsHarness.Supervisor)
    reporter = Process.whereis(CmsHarness.WorkingCopyReporter)
    ref = Process.monitor(reporter)

    # The exact failure: a report run in the reporter's process, no sandbox
    # owner. It crashes — that is not what is under test.
    send(reporter, :report)
    assert_receive {:DOWN, ^ref, :process, ^reporter, _reason}, 5_000

    # What is: the restarted reporter does not report again by itself, so there
    # is no second crash and the tree stands.
    restarted = wait_for_restart(reporter)
    restarted_ref = Process.monitor(restarted)
    refute_receive {:DOWN, ^restarted_ref, :process, _, _}, 1_000
    assert Process.alive?(supervisor)
  end

  defp wait_for_restart(old),
    do: restarted(Process.whereis(CmsHarness.WorkingCopyReporter), old)

  defp restarted(pid, old) when is_pid(pid) and pid != old, do: pid

  defp restarted(_pid, old) do
    receive do
    after
      20 -> wait_for_restart(old)
    end
  end
end
