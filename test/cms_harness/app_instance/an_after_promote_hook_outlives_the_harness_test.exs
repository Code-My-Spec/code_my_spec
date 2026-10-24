defmodule CmsHarness.AppInstance.AnAfterPromoteHookOutlivesTheHarnessTest do
  @moduledoc """
  Issue 0597863f: the `after-promote` recipe restarts the harness it runs under.
  As a child of that harness, writing to a pipe back to it, it died of SIGPIPE
  once a slow shutdown (60s on 2026-10-20) closed the pipe — before it started
  the replacement — and nothing listened on :4004 for fifteen minutes.

  Run apart from the harness, with its output in a file and its exit status in
  another, it outlives the process it replaces. The shell line and the wait for
  its status are checked here without running anything.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance.Runner.Local

  @moduletag :tmp_dir

  describe "the line that runs the recipe" do
    test "is detached: no stdin, no pipe back to the caller, backgrounded" do
      line = Local.detached_after_promote("/tmp/ap.log", "/tmp/ap.log.status", false)

      assert line =~ "nohup bash -c "
      assert line =~ "> /dev/null 2>&1 < /dev/null &"
      assert line =~ "echo $!"
    end

    test "keeps the recipe's output in a file and its exit status in another" do
      line = Local.detached_after_promote("/tmp/ap.log", "/tmp/ap.log.status", false)

      assert line =~ "just after-promote >> '\\''/tmp/ap.log'\\'' 2>&1 < /dev/null"
      assert line =~ "echo $? > '\\''/tmp/ap.log.status'\\''"
    end

    test "gets its own session where setsid exists, and not where it does not" do
      assert Local.detached_after_promote("/l", "/s", true) =~ ~r/^setsid nohup /
      refute Local.detached_after_promote("/l", "/s", false) =~ "setsid"
    end
  end

  describe "waiting for the recipe's status" do
    test "exit 0 is success", %{tmp_dir: dir} do
      status = Path.join(dir, "status")
      File.write!(status, "0\n")

      assert Local.await_status(status, "log", 1_000, 10) == :ok
    end

    test "any other status is a failure that names the log", %{tmp_dir: dir} do
      status = Path.join(dir, "status")
      File.write!(status, "1\n")

      assert {:error, message} = Local.await_status(status, "the.log", 1_000, 10)
      assert message =~ "failed (1)"
      assert message =~ "the.log"
    end

    test "a status that arrives while waiting is picked up", %{tmp_dir: dir} do
      status = Path.join(dir, "status")
      test = self()

      spawn(fn ->
        Process.sleep(60)
        File.write!(status, "0\n")
        send(test, :written)
      end)

      assert Local.await_status(status, "log", 2_000, 10) == :ok

      # await_status only needs to observe the file write; the spawned
      # process's own send/2 right after it is a separate, later step that
      # can still be in flight on a loaded scheduler.
      assert_receive :written, 500
    end

    test "no status in time is an error, not a hang", %{tmp_dir: dir} do
      assert {:error, message} =
               Local.await_status(Path.join(dir, "never"), "the.log", 50, 10)

      assert message =~ "did not finish in time"
    end
  end
end
