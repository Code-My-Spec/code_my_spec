defmodule CodeMySpec.ProjectSync.FileWatcherServer do
  @moduledoc """
  Singleton GenServer that watches project directories for file changes
  and runs FileSync + ComponentSync.

  Auto-watches all linked projects on boot. New directories can also be
  registered via `ensure_watching/1`.

  On file change: debounces events, runs FileSync (classify + validate)
  and ComponentSync (upsert components from files).
  """
  use GenServer
  require Logger

  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Users.Scope

  @watched_subdirs [".code_my_spec/spec", ".code_my_spec/rules", ".code_my_spec/qa", ".code_my_spec/architecture", ".code_my_spec/integrations", "lib", "test"]
  @debounce_ms 100

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ensure the given scope's project directory is being watched.
  No-op if already watching that directory or if scope has no cwd.
  """
  @spec ensure_watching(Scope.t(), GenServer.name()) :: :ok | :ignored
  def ensure_watching(scope, name \\ __MODULE__)

  def ensure_watching(%Scope{cwd: nil}, _name), do: :ignored

  def ensure_watching(%Scope{cwd: cwd} = scope, name) when is_binary(cwd) do
    GenServer.cast(name, {:ensure_watching, cwd, scope})
  end

  @doc """
  Returns the list of currently watched project root directories.
  """
  @spec watched_dirs(GenServer.name()) :: [String.t()]
  def watched_dirs(name \\ __MODULE__) do
    GenServer.call(name, :watched_dirs)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    state = %{watchers: %{}, pending: %{}, debounce_timer: nil}
    watchers = watch_all_linked_projects(state)
    {:ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:ensure_watching, project_root, scope}, state) do
    if Map.has_key?(state.watchers, project_root) do
      {:noreply, state}
    else
      case start_watcher(project_root) do
        {:ok, watcher_pid} ->
          entry = %{watcher_pid: watcher_pid, scope: scope}
          watchers = Map.put(state.watchers, project_root, entry)
          {:noreply, %{state | watchers: watchers}}

        {:error, reason} ->
          Logger.warning("[FileWatcher] Could not watch #{project_root}: #{inspect(reason)}")
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_call(:watched_dirs, _from, state) do
    {:reply, Map.keys(state.watchers), state}
  end

  @impl true
  def handle_info({:file_event, watcher_pid, {path, events}}, state) do
    if relevant_event?(events) do
      Logger.debug("[FileWatcher] File event: #{path} #{inspect(events)}")
      pending = Map.update(state.pending, watcher_pid, MapSet.new([path]), &MapSet.put(&1, path))
      if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)
      timer = Process.send_after(self(), :flush, @debounce_ms)
      {:noreply, %{state | pending: pending, debounce_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    Enum.each(state.pending, fn {watcher_pid, paths} ->
      flush_watcher(watcher_pid, paths, state.watchers)
    end)

    {:noreply, %{state | pending: %{}, debounce_timer: nil}}
  end

  def handle_info({:file_event, watcher_pid, :stop}, state) do
    case find_root_by_watcher(watcher_pid, state.watchers) do
      nil ->
        {:noreply, state}

      project_root ->
        Logger.warning("[FileWatcher] Watcher stopped for #{project_root}")
        {:noreply, %{state | watchers: Map.delete(state.watchers, project_root)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)
    :ok
  end

  # --- Private ---

  defp start_watcher(project_root) do
    dirs =
      @watched_subdirs
      |> Enum.map(&Path.join(project_root, &1))
      |> Enum.filter(&File.dir?/1)

    case dirs do
      [] ->
        {:error, :no_watchable_dirs}

      dirs ->
        case FileSystem.start_link(dirs: dirs) do
          {:ok, pid} ->
            FileSystem.subscribe(pid)
            Logger.info("[FileWatcher] Watching #{project_root}: #{Enum.join(dirs, ", ")}")
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp relevant_event?(events) do
    Enum.any?(events, &(&1 in [:modified, :created, :removed, :renamed]))
  end

  defp flush_watcher(watcher_pid, paths, watchers) do
    case find_root_by_watcher(watcher_pid, watchers) do
      nil ->
        :ok

      project_root ->
        %{scope: scope} = watchers[project_root]

        try do
          start = System.monotonic_time(:millisecond)
          file_count = paths |> Enum.to_list() |> length()

          {:ok, file_result} = FileSync.sync(scope, base_dir: project_root)

          {:ok, comp_result} =
            FileComponentSync.sync_from_files(scope,
              base_dir: project_root,
              changed_paths: file_result.changed_paths
            )

          ms = System.monotonic_time(:millisecond) - start

          Logger.info(
            "[FileWatcher] #{file_count} event(s) → " <>
              "#{length(file_result.changed_paths)} file(s) changed, " <>
              "#{length(comp_result.changed_component_ids)} component(s) changed " <>
              "in #{ms}ms"
          )
        rescue
          e ->
            Logger.error(
              "[FileWatcher] Error processing file changes for #{project_root}: #{Exception.message(e)}"
            )
        end
    end
  end

  defp find_root_by_watcher(watcher_pid, watchers) do
    Enum.find_value(watchers, fn {root, %{watcher_pid: pid}} ->
      if pid == watcher_pid, do: root
    end)
  end

  defp watch_all_linked_projects(state) do
    import Ecto.Query

    alias CodeMySpec.Projects.Project

    projects =
      Project
      |> where([p], not is_nil(p.local_path))
      |> CodeMySpec.Repo.all()

    Enum.reduce(projects, state.watchers, fn project, watchers ->
      root = project.local_path

      if Map.has_key?(watchers, root) or not File.dir?(root) do
        watchers
      else
        case Scope.for_local_project(project) do
          {:ok, scope} ->
            case start_watcher(root) do
              {:ok, watcher_pid} ->
                Logger.info("[FileWatcher] Auto-watching #{project.name} at #{root}")
                Map.put(watchers, root, %{watcher_pid: watcher_pid, scope: scope})

              {:error, reason} ->
                Logger.warning("[FileWatcher] Could not watch #{root}: #{inspect(reason)}")
                watchers
            end

          {:error, _} ->
            watchers
        end
      end
    end)
  end
end
