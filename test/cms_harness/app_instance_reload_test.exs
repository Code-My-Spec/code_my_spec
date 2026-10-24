defmodule CmsHarness.AppInstanceReloadTest do
  @moduledoc """
  `reload_app`: a promote's default. The running app is migrated and
  hot-reloaded in place by the project's `reload` recipe, then main runs its
  after-promote hook exactly as a restart does. It restarts instead when the
  app is not running or there is no recipe, and a failed reload runs no hook,
  because the restart the server sends next runs it.

  `async: false` for the same reason as every `app_instance_rig` test: the
  runner is a named singleton configured through application env.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  defp hooks, do: Enum.count(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1))
  defp launches, do: Enum.count(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))
  defp reloads, do: Enum.count(FakeAppInstanceRunner.calls(), &match?({:reload, _}, &1))

  defp running_app(recipes) do
    rig =
      app_instance_rig(
        current_commit: "launch0",
        recipe: Map.merge(%{"after-promote" => true}, recipes),
        reload_result: :ok
      )

    assert %{"status" => "ok", "app_status" => "serving"} =
             push_app_event_as_main("ensure_app_running")

    rig
  end

  test "a running app is reloaded in place, reports the new serving commit, and runs the hook once" do
    %{root: root} = running_app(%{"reload" => true})
    FakeAppInstanceRunner.configure(current_commit: "reload1")
    launched = launches()

    result = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert %{
             "status" => "ok",
             "app_status" => "serving",
             "app_commit" => "launch0",
             "app_serving_commit" => "reload1",
             "app_action" => "reloaded"
           } = result

    assert launches() == launched, "a reload must not launch a second app process"
    assert reloads() == 1
    assert hooks() == 1

    assert %{"app_commit" => "launch0", "app_serving_commit" => "reload1"} =
             push_app_event("ensure_app_running"),
           "an ensure after a reload must report the reloaded commit, not read as stale"
  end

  test "a project with no reload recipe is restarted, and says why" do
    %{root: root} = running_app(%{"reload" => false})

    result = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert %{"status" => "ok", "app_action" => "restarted", "app_action_reason" => why} = result
    assert why =~ "no reload recipe"
    assert reloads() == 0
    assert hooks() == 1
  end

  test "an app that is not running is restarted rather than reloaded" do
    %{root: root} =
      app_instance_rig(current_commit: "c0", recipe: %{"reload" => true, "after-promote" => true})

    result = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert %{"status" => "ok", "app_action" => "restarted", "app_action_reason" => why} = result
    assert why =~ "not running"
    assert reloads() == 0
  end

  test "a failed reload answers an error and runs no hook" do
    %{root: root} = running_app(%{"reload" => true})
    FakeAppInstanceRunner.put_reload_result({:error, "`just reload` failed (1): boom"})

    assert %{"status" => "error", "reason" => reason} = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert reason =~ "boom"
    assert hooks() == 0, "the restart that follows a failed reload runs the hook, not the reload"
  end

  # :4000 reloading itself: the caller that would restart it is the app that
  # went down, so the harness restarts it (2026-10-16, down 02:15-02:19).
  test "a failed reload that leaves the app down is restarted here" do
    %{root: root} = running_app(%{"reload" => true})
    FakeAppInstanceRunner.put_reload_result({:error, "`just reload` failed (7): refused"})
    FakeAppInstanceRunner.put_probes([:down])
    launched = launches()

    result = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert %{"status" => "ok", "app_action" => "restarted", "app_action_reason" => why} = result
    assert why =~ "left the app down"
    assert launches() == launched + 1
    assert hooks() == 1
  end

  test "a reload the app does not survive answers an error" do
    %{root: root} = running_app(%{"reload" => true})
    FakeAppInstanceRunner.put_probe(:erroring)

    assert %{"status" => "error", "reason" => reason} = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert reason =~ "erroring"
    assert hooks() == 0
  end
end
