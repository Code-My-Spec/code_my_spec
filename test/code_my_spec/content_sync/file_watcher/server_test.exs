defmodule CodeMySpec.ContentSync.FileWatcher.ServerTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}
  import ExUnit.CaptureLog

  alias CodeMySpec.ContentSync.FileWatcher
  alias CodeMySpec.Users.Scope

  # ============================================================================
  # Test Setup and Helpers
  # ============================================================================

  setup do
    # Create unique test directory
    dir = Path.join(System.tmp_dir!(), "fw_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Create test scope
    user = user_fixture()
    account = account_fixture(%{name: "Test Account"})

    project =
      project_fixture(
        %Scope{
          user: user,
          active_account: account,
          active_account_id: account.id
        },
        %{name: "Test Project"}
      )

    scope = %Scope{
      user: user,
      active_account: account,
      active_account_id: account.id,
      active_project: project,
      active_project_id: project.id
    }

    # Automatic cleanup via on_exit
    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    %{dir: dir, scope: scope}
  end

  defp mock_sync_fn(test_pid) do
    fn scope, _directory ->
      send(test_pid, {:sync_called, scope})
      {:ok, %{total_files: 1, successful: 1, errors: 0, duration_ms: 10}}
    end
  end

  # ============================================================================
  # Initialization Tests
  # ============================================================================

  describe "init/1 - successful initialization" do
    test "starts with valid config", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      assert Process.alive?(pid)
    end

    test "loads state with correct scope", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      state = :sys.get_state(pid)
      assert state.scope.active_account_id == scope.active_account_id
      assert state.scope.active_project_id == scope.active_project_id
    end

    test "loads state with correct directory", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      state = :sys.get_state(pid)
      assert state.watched_directory == dir
    end

    test "initializes with nil debounce_timer", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      state = :sys.get_state(pid)
      assert state.debounce_timer == nil
    end

    test "stores custom debounce_ms", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 50,
             enabled: true
           ]}
        )

      state = :sys.get_state(pid)
      assert state.debounce_ms == 50
    end

    test "stores custom sync_fn", %{dir: dir, scope: scope} do
      sync_fn = fn _, _ -> {:ok, %{}} end

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      state = :sys.get_state(pid)
      assert state.sync_fn == sync_fn
    end
  end

  describe "init/1 - conditional startup" do
    test "returns :ignore when enabled is false", %{dir: dir, scope: scope} do
      assert :ignore =
               FileWatcher.start_link(
                 directory: dir,
                 scope: scope,
                 enabled: false
               )
    end

    test "returns :ignore when enabled is nil", %{dir: dir, scope: scope} do
      assert :ignore =
               FileWatcher.start_link(
                 directory: dir,
                 scope: scope,
                 enabled: nil
               )
    end
  end

  describe "init/1 - configuration validation errors" do
    test "returns error when directory does not exist", %{scope: scope} do
      Process.flag(:trap_exit, true)

      result =
        FileWatcher.start_link(
          directory: "/nonexistent/directory",
          scope: scope,
          enabled: true
        )

      assert match?({:error, _}, result)
    end

    test "returns error when directory is a file", %{scope: scope} do
      file_path = Path.join(System.tmp_dir!(), "test_file_#{System.unique_integer([:positive])}")
      File.write!(file_path, "test")

      Process.flag(:trap_exit, true)

      result =
        FileWatcher.start_link(
          directory: file_path,
          scope: scope,
          enabled: true
        )

      File.rm!(file_path)

      assert match?({:error, _}, result)
    end

    test "returns error when directory is nil", %{scope: scope} do
      Process.flag(:trap_exit, true)

      result =
        FileWatcher.start_link(
          directory: nil,
          scope: scope,
          enabled: true
        )

      assert match?({:error, _}, result)
    end

    test "returns error when scope is nil", %{dir: dir} do
      Process.flag(:trap_exit, true)

      result =
        FileWatcher.start_link(
          directory: dir,
          scope: nil,
          enabled: true
        )

      assert match?({:error, _}, result)
    end
  end

  # ============================================================================
  # File Event Handling Tests
  # ============================================================================

  describe "handle_info/2 - file event handling" do
    test "receives file_event messages", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      file_path = Path.join(dir, "test.md")
      send(pid, {:file_event, self(), {file_path, [:modified]}})

      # GenServer should still be alive after processing
      assert Process.alive?(pid)
    end

    test "starts debounce timer on relevant file event", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 50,
             enabled: true
           ]}
        )

      file_path = Path.join(dir, "test.md")
      send(pid, {:file_event, self(), {file_path, [:modified]}})

      # Give a moment for message processing
      :timer.sleep(5)

      state = :sys.get_state(pid)
      assert state.debounce_timer != nil
      assert is_reference(state.debounce_timer)
    end

    test "cancels existing timer when new event arrives", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 50,
             enabled: true
           ]}
        )

      file_path = Path.join(dir, "test.md")

      # Send first event
      send(pid, {:file_event, self(), {file_path, [:modified]}})
      :timer.sleep(5)
      state1 = :sys.get_state(pid)
      first_timer = state1.debounce_timer

      # Send second event
      send(pid, {:file_event, self(), {file_path, [:modified]}})
      :timer.sleep(5)
      state2 = :sys.get_state(pid)
      second_timer = state2.debounce_timer

      # Timer should be different (new timer)
      assert first_timer != second_timer
      assert second_timer != nil
    end

    test "handles :modified events", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 500,
             enabled: true
           ]}
        )

      send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:modified]}})

      state = :sys.get_state(pid)
      assert state.debounce_timer != nil
    end

    test "handles :created events", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 500,
             enabled: true
           ]}
        )

      send(pid, {:file_event, self(), {Path.join(dir, "new.md"), [:created]}})

      state = :sys.get_state(pid)
      assert state.debounce_timer != nil
    end

    test "handles :removed events", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 500,
             enabled: true
           ]}
        )

      send(pid, {:file_event, self(), {Path.join(dir, "deleted.md"), [:removed]}})

      state = :sys.get_state(pid)
      assert state.debounce_timer != nil
    end

    test "ignores irrelevant events", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 500,
             enabled: true
           ]}
        )

      send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:other]}})

      state = :sys.get_state(pid)
      assert state.debounce_timer == nil
    end

    test "handles multiple event types", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:modified, :created]}})
      :timer.sleep(5)

      state = :sys.get_state(pid)
      assert state.debounce_timer != nil
    end
  end

  # ============================================================================
  # Sync Trigger Tests
  # ============================================================================

  describe "handle_info/2 - trigger sync" do
    test "triggers sync after debounce", %{dir: dir, scope: scope} do
      test_pid = self()
      sync_fn = mock_sync_fn(test_pid)

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      file_path = Path.join(dir, "test.md")
      send(pid, {:file_event, self(), {file_path, [:modified]}})

      # Wait for sync to be called
      assert_receive {:sync_called, ^scope}, 100
    end

    test "clears timer after sync", %{dir: dir, scope: scope} do
      test_pid = self()
      sync_fn = mock_sync_fn(test_pid)

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:modified]}})

      # Wait for sync
      assert_receive {:sync_called, _}, 100

      state = :sys.get_state(pid)
      assert state.debounce_timer == nil
    end

    test "can be triggered directly", %{dir: dir, scope: scope} do
      test_pid = self()
      sync_fn = mock_sync_fn(test_pid)

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      send(pid, :trigger_sync)

      assert_receive {:sync_called, ^scope}, 100
    end

    test "passes correct scope to sync function", %{dir: dir, scope: scope} do
      test_pid = self()

      sync_fn = fn received_scope, _directory ->
        send(test_pid, {:scope_received, received_scope})
        {:ok, %{total_files: 1, successful: 1, errors: 0, duration_ms: 10}}
      end

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      send(pid, :trigger_sync)

      assert_receive {:scope_received, received_scope}, 100
      assert received_scope.active_account_id == scope.active_account_id
      assert received_scope.active_project_id == scope.active_project_id
    end
  end

  # ============================================================================
  # Debounce Behavior Tests
  # ============================================================================

  describe "debounce behavior" do
    test "multiple rapid events only trigger one sync", %{dir: dir, scope: scope} do
      test_pid = self()

      sync_fn = fn _s, _directory ->
        send(test_pid, :synced)
        {:ok, %{total_files: 1, successful: 1, errors: 0, duration_ms: 10}}
      end

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 20,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      # Send multiple rapid events
      for _i <- 1..5 do
        send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:modified]}})
      end

      # Should only receive one sync call
      assert_receive :synced, 100
      refute_receive :synced, 50
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "continues running when sync fails", %{dir: dir, scope: scope} do
      sync_fn = fn _scope, _directory ->
        {:error, :sync_failed}
      end

      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             sync_fn: sync_fn,
             enabled: true
           ]}
        )

      capture_log(fn ->
        send(pid, :trigger_sync)

        # Give time for sync to fail
        :timer.sleep(20)

        # Process should still be alive
        assert Process.alive?(pid)

        # Should still handle new events
        send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:modified]}})
        assert Process.alive?(pid)
      end)
    end

    test "handles unexpected messages gracefully", %{dir: dir, scope: scope} do
      pid =
        start_supervised!(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      send(pid, :unexpected)
      send(pid, {:unexpected, :message})
      send(pid, %{unexpected: :map})

      # Process should still be alive
      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # Termination Tests
  # ============================================================================

  describe "termination" do
    test "stops cleanly", %{dir: dir, scope: scope} do
      {:ok, pid} =
        start_supervised(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 10,
             enabled: true
           ]}
        )

      assert Process.alive?(pid)

      stop_supervised(FileWatcher)

      refute Process.alive?(pid)
    end

    test "stops cleanly with active timer", %{dir: dir, scope: scope} do
      {:ok, pid} =
        start_supervised(
          {FileWatcher,
           [
             directory: dir,
             scope: scope,
             debounce_ms: 50,
             enabled: true
           ]}
        )

      # Start a timer
      send(pid, {:file_event, self(), {Path.join(dir, "test.md"), [:modified]}})
      :timer.sleep(5)

      state = :sys.get_state(pid)
      assert state.debounce_timer != nil

      # Stop with active timer
      stop_supervised(FileWatcher)

      refute Process.alive?(pid)
    end
  end
end
