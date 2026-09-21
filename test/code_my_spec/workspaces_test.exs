defmodule CodeMySpec.WorkspacesTest do
  # Sync: writes `:code_my_spec, CodeMySpec.Workspaces` — the fake runner and the
  # boot timings — which `CodeMySpecWeb.IntakeLive.WorkspaceTest` also writes.
  # Moving either to async needs the runner threaded into the watcher rather than
  # swapped globally; `Workspaces.watch/1` starts it as a supervised task and
  # resolves the runner from application env at call time.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.Runner
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

      assert [{container_name, app_name, port, env}] = FakeWorkspaceRunner.calls()

      # The instance is told which working copy it is, which is what lets it
      # onboard itself on the way up. Without it a container comes up holding an
      # application and belonging to nobody: no identity, no row the visitor can
      # see, no preview address.
      assert {"CMS_WORKING_COPY_ID", working_copy_id} =
               List.keyfind(env, "CMS_WORKING_COPY_ID", 0),
             "the container was started without an identity, so whatever it runs " <>
               "is not a working copy anybody owns. Got: #{inspect(env)}"

      assert {:ok, _} = Ecto.UUID.cast(working_copy_id)
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

    # LiveView mounts twice for one page view — disconnected, then over the
    # socket — so this is what every visitor did. Each call took a fresh port
    # and started the container again, leaving the row pointing at the second
    # instance and two watchers polling for it.
    test "one that is still coming up is not started alongside itself" do
      fake(healthy?: false, alive?: true)
      scope = full_scope_fixture()

      {:ok, booting} = Workspaces.boot(scope)
      assert {:ok, second} = Workspaces.boot(scope)

      assert second.port == booting.port
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

  # Never exercised by `boot/1` above — the fake runner configured for this
  # whole file is neither `Runner.Docker` nor `Runner.Local`, so a test only
  # through `boot/1` would never actually reach either branch. This is the
  # exact shape of gap that let the two disagree in production: the harness
  # joined under its real bare-metal root, the server had recorded the
  # container one from this same function, and `cms harness` reported the
  # mismatch as `:working_copy_missing` on agent restore rather than as a
  # wrong path, since nothing compares the two directly.
  describe "instance_root/1" do
    setup do
      original = Application.get_env(:code_my_spec, CodeMySpec.Workspaces, [])
      on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.Workspaces, original) end)
      :ok
    end

    test "a Docker-run instance lands where the entrypoint always puts it" do
      Application.put_env(:code_my_spec, CodeMySpec.Workspaces, runner: Runner.Docker)
      scope = full_scope_fixture(%{name: "Widget Tracker"})

      assert Workspaces.instance_root(scope.active_project) == "/workspace/widget_tracker"
    end

    test "a bare-metal instance is asked where it actually landed, not assumed" do
      Application.put_env(:code_my_spec, CodeMySpec.Workspaces, runner: Runner.Local)
      scope = full_scope_fixture(%{name: "Widget Tracker"})
      project = scope.active_project

      expected = Runner.Local.root("cms-workspace-#{project.id}", "widget_tracker")

      refute expected == "/workspace/widget_tracker", """
      the premise failed: this test needs the bare-metal root to actually
      differ from the container one, or it cannot tell "asked correctly"
      from "still assuming the container path by coincidence"
      """

      assert Workspaces.instance_root(project) == expected
    end
  end
end
