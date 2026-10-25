defmodule CmsHarness.AppInstanceHeadMovedTest do
  @moduledoc """
  A copy's app is brought onto the copy's HEAD when a merge moves it: migrated
  and reloaded, or restarted when mix.lock, mix.exs or config changed, which
  the code reloader cannot pick up. It used to keep serving the old commit
  against an unmigrated database, or fail to recompile, until someone called
  `restart_app`.

  `async: false` for the same reason as every `app_instance_rig` test: the
  runner is a named singleton configured through application env.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  defp count(call), do: Enum.count(FakeAppInstanceRunner.calls(), &match?({^call, _}, &1))

  defp running_copy do
    rig =
      app_instance_rig(
        current_commit: "launch0",
        recipe: %{"reload" => true},
        reload_result: :ok
      )

    assert %{"status" => "ok", "app_status" => "serving"} = push_app_event("ensure_app_running")
    rig
  end

  test "a copy whose HEAD moved is migrated and reloaded onto it" do
    %{root: root} = running_copy()
    FakeAppInstanceRunner.configure(current_commit: "merged1", changed_paths: ["lib/a.ex"])

    assert %{"app_action_reason" => why} = push_app_event("ensure_app_running")
    assert why =~ "HEAD moved"

    sync_after_reply(root)
    assert count(:reload) == 1
    assert %{"app_serving_commit" => "merged1"} = push_app_event("ensure_app_running")
  end

  test "a merge that changed mix.lock restarts the app rather than reloading it" do
    %{root: root} = running_copy()
    launched = count(:launch)
    FakeAppInstanceRunner.configure(current_commit: "merged1", changed_paths: ["mix.lock"])

    push_app_event("ensure_app_running")
    sync_after_reply(root)

    assert count(:reload) == 0
    assert count(:launch) == launched + 1
  end

  test "a reload asked for after config changed restarts instead, and says why" do
    %{root: root} =
      app_instance_rig(current_commit: "launch0", recipe: %{"reload" => true}, reload_result: :ok)

    assert %{"app_status" => "serving"} = push_app_event_as_main("ensure_app_running")
    FakeAppInstanceRunner.configure(current_commit: "merged1", changed_paths: ["config/dev.exs"])

    result = push_app_event_as_main("reload_app")
    sync_after_reply(root)

    assert %{"app_action" => "restarted", "app_action_reason" => why} = result
    assert why =~ "config"
  end

  test "a HEAD it already tried is not tried again on every check" do
    %{root: root} = running_copy()
    FakeAppInstanceRunner.configure(current_commit: "merged1", changed_paths: ["lib/a.ex"])
    FakeAppInstanceRunner.put_reload_result({:error, "`just reload` failed (1): boom"})

    push_app_event("ensure_app_running")
    sync_after_reply(root)
    push_app_event("ensure_app_running")
    sync_after_reply(root)

    assert count(:reload) == 1
  end
end
