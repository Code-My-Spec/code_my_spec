defmodule CmsHarness.FakeServerLifecycleTest do
  use ExUnit.Case, async: false

  alias CmsHarnessTest.FakeServer

  test "stale reconnects cannot redirect commands away from the expected harness" do
    FakeServer.start()
    stale_channel = start_supervised!({Agent, fn -> nil end})
    assert :ok = FakeServer.expect_harness("current-copy")
    assert :ok = FakeServer.channel_joined(stale_channel, "old-copy")

    assert_raise RuntimeError, ~r/no channel has joined/, fn ->
      FakeServer.push_app_event("ensure_app_running")
    end

    assert :ok = FakeServer.channel_joined(self(), "current-copy")
    first_ref = FakeServer.push_app_event("ensure_app_running")
    assert_receive {:push_app_event, "ensure_app_running", %{"ref" => ^first_ref}}

    assert :ok = FakeServer.channel_joined(stale_channel, "old-copy")
    reload_ref = FakeServer.push_app_event("reload_app")
    assert_receive {:push_app_event, "reload_app", %{"ref" => ^reload_ref}}
  end

  test "ordered cleanup owns the endpoint and PubSub after the test process exits" do
    %{endpoint: endpoint} = FakeServer.start()
    pubsub = Process.whereis(FakeServer.PubSub.Supervisor)
    assert is_pid(pubsub)

    # Registered last, this runs before FakeServer's cleanup callback, but
    # after the process that started both supervisors has exited.
    on_exit(fn ->
      assert Process.alive?(endpoint)
      assert Process.alive?(pubsub)
      assert :ok = FakeServer.disconnect_everyone()
      refute Process.alive?(endpoint)
      assert Process.alive?(pubsub)
    end)
  end
end
