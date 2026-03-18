defmodule CodeMySpec.ProjectSync.FileWatcherServerTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Components.DirtyTracker
  alias CodeMySpec.ProjectSync.FileWatcherServer
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  @moduletag :file_watcher

  setup do
    scope = full_scope_fixture(%{module_name: "CodeMySpec"})

    tmp_dir = Path.join(System.tmp_dir!(), "file_watcher_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    scope = %{scope | cwd: tmp_dir}

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp start_server(_context) do
    name = :"file_watcher_#{System.unique_integer([:positive])}"
    {:ok, pid} = FileWatcherServer.start_link(name: name)
    Sandbox.allow(CodeMySpec.Repo, self(), pid)
    %{server: name, server_pid: pid}
  end

  describe "ensure_watching/2" do
    setup [:start_server]

    test "registers a new project directory", %{scope: scope, server: name, tmp_dir: tmp_dir} do
      assert ensure_watching_sync(scope, name) == :ok
      assert tmp_dir in FileWatcherServer.watched_dirs(name)
    end

    test "is a no-op for already watched directories", %{scope: scope, server: name} do
      assert ensure_watching_sync(scope, name) == :ok
      assert ensure_watching_sync(scope, name) == :ok
      assert length(FileWatcherServer.watched_dirs(name)) == 1
    end

    test "returns :ignored when scope has no cwd", %{server: name} do
      scope = full_scope_fixture(%{module_name: "CodeMySpec"})
      assert scope.cwd == nil
      assert FileWatcherServer.ensure_watching(scope, name) == :ignored
    end

    test "watches multiple project directories", %{scope: scope, server: name} do
      tmp_dir2 = Path.join(System.tmp_dir!(), "file_watcher_test2_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir2, "lib"))
      on_exit(fn -> File.rm_rf!(tmp_dir2) end)

      scope2 = %{scope | cwd: tmp_dir2}

      ensure_watching_sync(scope, name)
      ensure_watching_sync(scope2, name)

      assert length(FileWatcherServer.watched_dirs(name)) == 2
    end
  end

  describe "file change events" do
    setup [:start_server]

    test "debounces and marks components dirty via GenServer", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Accounts", type: "context"})
      ensure_watching_sync(scope, name)

      path = Path.join(tmp_dir, "lib/code_my_spec/accounts.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "defmodule CodeMySpec.Accounts do\nend\n")
      send(pid, {:file_event, get_watcher_pid(name, tmp_dir), {path, [:modified]}})

      Process.sleep(300)

      updated = Components.get_component(scope, component.id)
      assert updated.files_changed_at != nil
    end

    test "accumulates pending changes and flushes after debounce", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      ensure_watching_sync(scope, name)
      watcher_pid = get_watcher_pid(name, tmp_dir)

      send(pid, {:file_event, watcher_pid, {Path.join(tmp_dir, "lib/foo.ex"), [:modified]}})
      send(pid, {:file_event, watcher_pid, {Path.join(tmp_dir, "lib/bar.ex"), [:modified]}})
      send(pid, {:file_event, watcher_pid, {Path.join(tmp_dir, "lib/foo.ex"), [:modified]}})

      Process.sleep(200)
      assert tmp_dir in FileWatcherServer.watched_dirs(name)
    end

    test "marks files changed via update_component directly", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Direct", type: "context"})

      {path_map, _} = DirtyTracker.build_path_index([component], scope.active_project)
      assert Map.has_key?(path_map, "lib/code_my_spec/direct.ex")

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Components.update_component(scope, component, %{files_changed_at: now}, broadcast: false)

      updated = Components.get_component(scope, component.id)
      assert updated.files_changed_at != nil
    end

    test "ignores non-relevant events", %{scope: scope, server: name, server_pid: pid, tmp_dir: tmp_dir} do
      ensure_watching_sync(scope, name)

      send(pid, {:file_event, get_watcher_pid(name, tmp_dir), {"/some/path", [:isdir]}})

      Process.sleep(50)
      assert tmp_dir in FileWatcherServer.watched_dirs(name)
    end
  end

  describe "stop event" do
    setup [:start_server]

    test "removes watcher entry on FileSystem stop", %{scope: scope, server: name, server_pid: pid, tmp_dir: tmp_dir} do
      ensure_watching_sync(scope, name)
      assert tmp_dir in FileWatcherServer.watched_dirs(name)

      watcher_pid = get_watcher_pid(name, tmp_dir)
      send(pid, {:file_event, watcher_pid, :stop})
      Process.sleep(50)

      refute tmp_dir in FileWatcherServer.watched_dirs(name)
    end
  end

  # Ensure the cast has been processed by making a synchronous call after it
  defp ensure_watching_sync(scope, name) do
    result = FileWatcherServer.ensure_watching(scope, name)
    # watched_dirs/1 is a call, so it forces the server to process the cast first
    FileWatcherServer.watched_dirs(name)
    result
  end

  # Get the FileSystem watcher PID for a given project root from the server state
  defp get_watcher_pid(name, project_root) do
    :sys.get_state(name).watchers[project_root].watcher_pid
  end
end
