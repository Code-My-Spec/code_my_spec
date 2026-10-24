defmodule CmsHarness.AppInstanceTest do
  @moduledoc """
  The deterministic parts of story 1108's app-lifecycle process, tested
  without spawning a real `mix phx.server` or touching Postgres.

  `AppInstance.result/1`/`url/2` are what the channel eventually reports back
  to the server as `app_status`/`app_url`/`app_commit` — see
  `WorkingCopies.record_app_status/2`. `safe_identifier?/1` is what stands
  between a database name derived from `mix.exs` and a shell string built
  from it in `clone_database/2`; a regression there is a command-injection
  seam, not a cosmetic bug.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance

  describe "result/1" do
    test "a copy nothing has started reports down with no address" do
      assert AppInstance.result(%AppInstance{}) ==
               %{instance_id: nil, status: "down", url: nil, commit: nil, serving_commit: nil}
    end

    test "a serving copy reports its own local address and commit" do
      state = %AppInstance{status: "serving", port: 51_234, commit: "abc123"}

      assert AppInstance.result(state) == %{
               instance_id: nil,
               status: "serving",
               url: "http://127.0.0.1:51234",
               commit: "abc123",
               serving_commit: "abc123"
             }
    end

    test "a reloaded copy serves its reload commit and keeps its launch commit" do
      state = %AppInstance{
        status: "serving",
        port: 1,
        commit: "launch0",
        serving_commit: "reload1"
      }

      assert %{commit: "launch0", serving_commit: "reload1"} = AppInstance.result(state)
    end

    test "an erroring copy still reports the address a 500 is coming from" do
      state = %AppInstance{status: "erroring", port: 51_234, commit: "abc123"}

      assert %{status: "erroring", url: "http://127.0.0.1:51234"} = AppInstance.result(state)
    end

    test "a stopped copy never carries the address it used to answer on" do
      # The exact failure story 1108 exists to prevent: a stale link on a
      # copy nothing is running any more, read as though it were live.
      state = %AppInstance{status: "down", port: 51_234, commit: "abc123"}

      assert AppInstance.result(state).url == nil
    end
  end

  describe "safe_identifier?/1" do
    test "an ordinary database name is safe" do
      assert AppInstance.safe_identifier?("metric_flow_dev_wc_a1b2c3d4")
    end

    test "nothing that could break out of a shell string is" do
      refute AppInstance.safe_identifier?("metric_flow_dev; rm -rf /")
      refute AppInstance.safe_identifier?("metric_flow_dev`whoami`")
      refute AppInstance.safe_identifier?("metric_flow_dev && echo pwned")
      refute AppInstance.safe_identifier?("metric_flow dev")
      refute AppInstance.safe_identifier?("")
    end

    test "not a string at all is not safe either" do
      refute AppInstance.safe_identifier?(nil)
    end
  end
end
