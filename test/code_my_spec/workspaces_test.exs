defmodule CodeMySpec.WorkspacesTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Workspaces
  alias CodeMySpecTest.FakeWorkspaceRunner

  setup do
    # Poll faster than the timeout, so a boot that will fail finishes inside
    # the test rather than outliving the fake runner it is calling.
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 200,
      poll_interval: 20
    )

    # Kills this test's watchers before clearing the config, in that order.
    # A watcher that outlives its test falls back to the default runner —
    # which is the real Docker one — and polls it for fifteen minutes.
    CodeMySpecTest.WorkspaceWatchers.reset_on_exit()

    :ok
  end

  defp fake(opts), do: start_supervised!({FakeWorkspaceRunner, opts})

  describe "boot/1 — it comes up" do
    test "the visitor gets somewhere to look at the running application" do
      fake(healthy?: true)
      scope = full_scope_fixture(%{name: "Widget Tracker"})
      Workspaces.subscribe_workspace(scope.active_project_id)

      assert {:ok, workspace} = Workspaces.boot(scope)
      assert workspace.status == :booting

      assert_receive {:booting, _}
      assert_receive {:running, running}, 2_000

      assert running.status == :running
      assert Workspaces.url(running) == "http://localhost:#{running.port}"
    end

    test "the project name is carried into the instance as an app name" do
      fake(healthy?: true)
      scope = full_scope_fixture(%{name: "Widget Tracker"})
      Workspaces.subscribe_workspace(scope.active_project_id)

      {:ok, workspace} = Workspaces.boot(scope)
      assert_receive {:running, _}, 2_000

      assert [{container_name, app_name, port}] = FakeWorkspaceRunner.calls()
      assert app_name == "widget_tracker"
      assert container_name == "cms-workspace-#{scope.active_project_id}"
      assert port == workspace.port
    end

    test "an already-running workspace is not started a second time" do
      fake(healthy?: true)
      scope = full_scope_fixture()
      Workspaces.subscribe_workspace(scope.active_project_id)

      {:ok, _} = Workspaces.boot(scope)
      assert_receive {:running, _}, 2_000

      running = Workspaces.get_workspace(scope)
      assert {:ok, ^running} = Workspaces.boot(scope)
      assert length(FakeWorkspaceRunner.calls()) == 1
    end
  end

  describe "progress" do
    test "the phase the container announces reaches the workspace" do
      fake(
        healthy?: false,
        alive?: true,
        logs: "\e[1;36m==> Fetching dependencies\e[0m"
      )

      scope = full_scope_fixture()
      Workspaces.subscribe_workspace(scope.active_project_id)

      {:ok, _} = Workspaces.boot(scope)

      assert_receive {:progress, progressing}, 2_000
      assert progressing.step == :fetching_deps
      assert Workspaces.progress(progressing) == 50
      assert Workspaces.progress_label(progressing) == "Fetching dependencies"

      # It never answers, so let the watcher reach its verdict rather than
      # leaving it polling a fake that is about to be torn down.
      assert_receive {:failed, _}, 2_000
    end

    test "a running workspace reads as complete whatever the last marker was" do
      fake(healthy?: true, logs: "\e[1;36m==> Starting Postgres\e[0m")
      scope = full_scope_fixture()
      Workspaces.subscribe_workspace(scope.active_project_id)

      {:ok, _} = Workspaces.boot(scope)
      assert_receive {:running, running}, 2_000

      assert Workspaces.progress(running) == 100
      assert Workspaces.progress_label(running) == "Running"
    end

    test "a phase that has not moved on does not re-broadcast" do
      fake(healthy?: false, alive?: true, logs: "\e[1;36m==> Starting Postgres\e[0m")
      scope = full_scope_fixture()
      Workspaces.subscribe_workspace(scope.active_project_id)

      {:ok, _} = Workspaces.boot(scope)

      assert_receive {:progress, _}, 2_000
      refute_receive {:progress, _}, 500
    end
  end

  describe "boot/1 — it does not come up" do
    test "a container that dies says so rather than spinning forever" do
      fake(healthy?: false, alive?: false)
      scope = full_scope_fixture()
      Workspaces.subscribe_workspace(scope.active_project_id)

      assert {:ok, _} = Workspaces.boot(scope)
      assert_receive {:failed, failed}, 2_000

      assert failed.status == :failed
      assert failed.error =~ "stopped before it finished starting up"
      assert Workspaces.url(failed) == nil
    end

    test "a container that never answers gives up and says so" do
      fake(healthy?: false, alive?: true)
      scope = full_scope_fixture()
      Workspaces.subscribe_workspace(scope.active_project_id)

      assert {:ok, _} = Workspaces.boot(scope)
      assert_receive {:failed, failed}, 3_000

      assert failed.error =~ "took too long to start"
    end

    test "the runner refusing outright is reported, not swallowed" do
      fake(start_result: {:error, "docker run exited 125"})
      scope = full_scope_fixture()

      assert {:error, "docker run exited 125"} = Workspaces.boot(scope)
      assert Workspaces.get_workspace(scope) == nil
    end
  end

  describe "get_workspace/1" do
    test "a scope with no project has no workspace" do
      assert Workspaces.get_workspace(user_scope_fixture()) == nil
    end
  end
end
