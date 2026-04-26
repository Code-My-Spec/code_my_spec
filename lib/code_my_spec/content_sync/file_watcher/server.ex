defmodule CodeMySpec.ContentSync.FileWatcher.Server do
  @moduledoc """
  GenServer implementation for FileWatcher.

  This module contains ONLY GenServer boilerplate and side effects.
  All business logic and decision-making is delegated to FileWatcher.Impl.

  Following Dave Thomas's pattern of separating execution strategy from logic.
  """

  use GenServer
  require Logger

  alias CodeMySpec.ContentSync.FileWatcher.Impl

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    with {:ok, config} <- Impl.build_config(opts),
         :ok <- Impl.validate_config(config),
         {:ok, _pid} <- subscribe_to_filesystem(config.directory) do
      state = Impl.new_state(config)

      Logger.info(
        "FileWatcher started: watching #{state.watched_directory} for account_id=#{state.scope.active_account_id} project_id=#{state.scope.active_project_id}"
      )

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    case Impl.handle_file_event(state, path, events) do
      {:schedule_sync, delay_ms, updated_state} ->
        # Perform side effect: cancel old timer if exists
        if state.debounce_timer do
          Process.cancel_timer(state.debounce_timer)
        end

        # Perform side effect: schedule new timer
        timer_ref = Process.send_after(self(), :trigger_sync, delay_ms)

        # Update state with new timer ref
        new_state = Impl.update_timer(updated_state, timer_ref)

        {:noreply, new_state}

      {:noreply, new_state} ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:trigger_sync, state) do
    # Get sync arguments from pure logic
    {scope, sync_fn, new_state} = Impl.handle_sync_trigger(state)

    # Perform side effect: call sync function
    case sync_fn.(scope, state.watched_directory) do
      {:ok, result} ->
        Logger.info("FileWatcher: ContentAdmin synced successfully",
          total: result.total_files,
          success: result.successful,
          errors: result.errors,
          duration_ms: result.duration_ms
        )

      {:error, reason} ->
        Logger.error("FileWatcher: ContentAdmin sync failed", reason: reason)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Perform side effect: cancel timer if exists
    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    :ok
  end

  # ============================================================================
  # FileSystem Integration (Side Effect)
  # ============================================================================

  @spec subscribe_to_filesystem(String.t()) :: {:ok, pid()} | {:error, term()}
  defp subscribe_to_filesystem(directory) do
    case FileSystem.start_link(dirs: [directory]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
