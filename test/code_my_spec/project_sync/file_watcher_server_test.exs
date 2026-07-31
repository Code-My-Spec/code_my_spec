defmodule CodeMySpec.ProjectSync.FileWatcherServerTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.ProjectSync.FileWatcherServer
  alias CodeMySpec.Dependencies
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures

  @moduletag :file_watcher

  setup do
    scope = full_scope_fixture(%{module_name: "CodeMySpec"})

    tmp_dir =
      Path.join(System.tmp_dir!(), "file_watcher_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    scope = %{
      scope
      | cwd: tmp_dir,
        environment: CodeMySpec.Environments.Environment.new(:local, tmp_dir)
    }

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp start_server(_context) do
    name = :"file_watcher_#{System.unique_integer([:positive])}"
    # Set shared mode so the GenServer can query DB during init
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    {:ok, pid} = FileWatcherServer.start_link(name: name)
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
      tmp_dir2 =
        Path.join(System.tmp_dir!(), "file_watcher_test2_#{System.unique_integer([:positive])}")

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

    test "ignores non-relevant events", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      ensure_watching_sync(scope, name)

      send(pid, {:file_event, get_watcher_pid(name, tmp_dir), {"/some/path", [:isdir]}})

      Process.sleep(50)
      assert tmp_dir in FileWatcherServer.watched_dirs(name)
    end
  end

  describe "stop event" do
    setup [:start_server]

    test "removes watcher entry on FileSystem stop", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      ensure_watching_sync(scope, name)
      assert tmp_dir in FileWatcherServer.watched_dirs(name)

      watcher_pid = get_watcher_pid(name, tmp_dir)
      send(pid, {:file_event, watcher_pid, :stop})
      Process.sleep(50)

      refute tmp_dir in FileWatcherServer.watched_dirs(name)
    end
  end

  describe "mix.lock polling" do
    setup [:start_server]

    test "schedules a hex sync when mix.lock mtime changes", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      lock_path = Path.join(tmp_dir, "mix.lock")
      File.write!(lock_path, ~s|%{"a": {:hex, :a, "1.0.0"}}|)

      ensure_watching_sync(scope, name)

      # Server now snapshots the current mtime as its baseline.
      initial = :sys.get_state(name).lock_mtimes[tmp_dir]
      assert is_integer(initial)

      # Bump mtime so the next poll observes a change.
      File.touch!(lock_path, initial + 5)

      send(pid, :poll_locks)
      _ = FileWatcherServer.watched_dirs(name)

      state = :sys.get_state(name)
      assert state.lock_mtimes[tmp_dir] == initial + 5

      assert is_reference(state.hex_sync_timers[tmp_dir]),
             "expected a debounce timer to be scheduled after mix.lock change"
    end

    test "no timer is scheduled when mix.lock mtime is unchanged", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "mix.lock"), ~s|%{}|)
      ensure_watching_sync(scope, name)

      send(pid, :poll_locks)
      _ = FileWatcherServer.watched_dirs(name)

      assert :sys.get_state(name).hex_sync_timers == %{}
    end

    test "no timer is scheduled when mix.lock is absent", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      ensure_watching_sync(scope, name)

      send(pid, :poll_locks)
      _ = FileWatcherServer.watched_dirs(name)

      refute Map.has_key?(:sys.get_state(name).hex_sync_timers, tmp_dir)
    end

    test "back-to-back lock changes coalesce into a single fresh timer", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      lock_path = Path.join(tmp_dir, "mix.lock")
      File.write!(lock_path, "%{}")
      ensure_watching_sync(scope, name)

      initial_mtime = :sys.get_state(name).lock_mtimes[tmp_dir]

      File.touch!(lock_path, initial_mtime + 1)
      send(pid, :poll_locks)
      _ = FileWatcherServer.watched_dirs(name)
      first_ref = :sys.get_state(name).hex_sync_timers[tmp_dir]
      assert is_reference(first_ref)

      File.touch!(lock_path, initial_mtime + 2)
      send(pid, :poll_locks)
      _ = FileWatcherServer.watched_dirs(name)
      second_ref = :sys.get_state(name).hex_sync_timers[tmp_dir]
      assert is_reference(second_ref)

      # The first timer was cancelled and replaced — `Process.cancel_timer`
      # on a cancelled ref returns `false` (no time remaining), while the
      # active second_ref returns an integer (ms remaining).
      assert Process.cancel_timer(first_ref) == false,
             "expected the first debounce timer to have been cancelled"

      assert is_integer(Process.cancel_timer(second_ref)),
             "expected the second debounce timer to still be active"
    end
  end

  describe "{:run_hex_sync, project_root, pass} dispatch" do
    setup [:start_server]

    # Projection is driven by what `mix.lock` says the project depends on, not
    # by what happens to be sitting in `deps/`. A directory left behind by a
    # removed dependency is indistinguishable from an installed one; a lock
    # entry cannot be left behind, because mix rewrites the lock whole.
    test "records the lock, then lands markdown for the packages it names", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      install_fixture_source(
        tmp_dir,
        "phoenix",
        "Phoenix",
        "Phoenix is a productive web framework."
      )

      File.write!(
        Path.join(tmp_dir, "mix.lock"),
        ~s|%{\n  "phoenix": {:hex, :phoenix, "1.8.1", "c", [:mix], [], "hexpm", "c2"}\n}\n|
      )

      ensure_watching_sync(scope, name)
      send(pid, {:run_hex_sync, tmp_dir, 1})

      target = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])

      assert wait_until(200, fn -> File.exists?(target) end),
             "expected projector to land Phoenix.md after {:run_hex_sync} dispatch"

      assert File.read!(target) =~ "productive web framework"
    end

    test "clears the pending timer ref from state after dispatch", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      ensure_watching_sync(scope, name)
      # Plant a fake timer ref so we can observe it being cleared.
      ref = make_ref()

      :sys.replace_state(name, fn state ->
        %{state | hex_sync_timers: Map.put(state.hex_sync_timers, tmp_dir, ref)}
      end)

      File.write!(
        Path.join(tmp_dir, "mix.lock"),
        ~s|%{\n  "phoenix": {:hex, :phoenix, "1.8.1", "c", [:mix], [], "hexpm", "c2"}\n}\n|
      )

      send(pid, {:run_hex_sync, tmp_dir, 1})
      _ = FileWatcherServer.watched_dirs(name)

      refute Map.has_key?(:sys.get_state(name).hex_sync_timers, tmp_dir)

      # The pass runs in a Task. Wait for it on an observable signal rather than
      # letting the test end underneath it — a task killed at teardown takes the
      # sandbox connection with it and logs an ownership crash that has nothing
      # to do with what is being tested.
      assert wait_until(500, fn -> Dependencies.list_dependencies(scope) != [] end)
    end
  end

  describe "boot snapshot" do
    test "snapshots mix.lock mtime for ensure_watching projects" do
      tmp_dir = Path.join(System.tmp_dir!(), "fw_boot_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      lock_path = Path.join(tmp_dir, "mix.lock")
      File.write!(lock_path, "%{}")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      scope = full_scope_fixture(%{module_name: "CodeMySpec"})
      scope = %{scope | cwd: tmp_dir}

      Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
      name = :"file_watcher_boot_#{System.unique_integer([:positive])}"
      {:ok, _pid} = FileWatcherServer.start_link(name: name)

      ensure_watching_sync(scope, name)

      mtime = :sys.get_state(name).lock_mtimes[tmp_dir]
      {:ok, %File.Stat{mtime: actual}} = File.stat(lock_path, time: :posix)

      assert mtime == actual,
             "expected boot-time snapshot to match mix.lock's actual mtime"
    end
  end

  describe "mailbox under flood" do
    setup [:start_server]

    test "drains 5000 synthetic file events without backing up", %{
      scope: scope,
      server: name,
      server_pid: pid,
      tmp_dir: tmp_dir
    } do
      ensure_watching_sync(scope, name)
      watcher_pid = get_watcher_pid(name, tmp_dir)

      # Use an unrecognized path so dispatch is a no-op (classify
      # returns nil → sync_path returns {:ok, %{changed_path: nil}})
      # and no DB queries fire. This isolates the watcher's mailbox
      # behavior from downstream work.
      noisy_path = Path.join(tmp_dir, "deps/noisy/file.txt")

      for _ <- 1..5000 do
        send(pid, {:file_event, watcher_pid, {noisy_path, [:modified]}})
      end

      assert wait_until(2_000, fn ->
               {:message_queue_len, len} = Process.info(pid, :message_queue_len)
               len == 0
             end),
             "expected the watcher's mailbox to drain within 2 seconds under a 5000-event flood"

      assert Process.alive?(pid)
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

  # Poll `check_fn` until it returns true or `timeout_ms` elapses.
  # Returns true on success, false on timeout. Used for asserting
  # async side effects (Task.start in the GenServer's handler).
  defp wait_until(timeout_ms, check_fn) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, check_fn)
  end

  defp do_wait_until(deadline, check_fn) do
    next_step(check_fn.(), System.monotonic_time(:millisecond) >= deadline, deadline, check_fn)
  end

  defp next_step(true, _expired, _deadline, _check_fn), do: true
  defp next_step(_check, true, _deadline, _check_fn), do: false

  defp next_step(_check, _expired, deadline, check_fn) do
    Process.sleep(20)
    do_wait_until(deadline, check_fn)
  end

  # Write a tiny fixture dependency module's source under
  # `<tmp_dir>/deps/<package>/lib/<module>.ex`. The hex doc projector
  # reads `@moduledoc`/`@doc` straight from source — no compilation, no
  # BEAMs. Mirrors the helper in `hex_doc_projector_test.exs`.
  defp install_fixture_source(tmp_dir, package, module, docstring) do
    source_path =
      Path.join([tmp_dir, "deps", package, "lib", "#{Macro.underscore(module)}.ex"])

    File.mkdir_p!(Path.dirname(source_path))

    source = """
    defmodule #{module} do
      @moduledoc #{inspect(docstring)}
    end
    """

    File.write!(source_path, source)
    source_path
  end
end
