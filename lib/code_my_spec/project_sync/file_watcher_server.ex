defmodule CodeMySpec.ProjectSync.FileWatcherServer do
  @moduledoc """
  Singleton GenServer that watches project directories for file changes and
  marks components dirty in the DB.

  Manages multiple project watchers keyed by project root directory. New
  directories are registered lazily via `ensure_watching/1` — typically called
  from agent task entry points where a scope with `cwd` is available.

  On file change: debounces events, maps paths to components, bumps
  `files_changed_at` on the component record.
  """
  use GenServer
  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.DirtyTracker
  alias CodeMySpec.Components.HierarchicalTree
  alias CodeMySpec.ProjectSync.StatusWriter
  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @watched_subdirs [".code_my_spec/spec", "lib", "test"]
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
    GenServer.call(name, {:ensure_watching, cwd, scope})
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
    {:ok, %{watchers: %{}, pending: %{}, debounce_timer: nil}}
  end

  @impl true
  def handle_call({:ensure_watching, project_root, scope}, _from, state) do
    if Map.has_key?(state.watchers, project_root) do
      {:reply, :ok, state}
    else
      case start_watcher(project_root) do
        {:ok, watcher_pid} ->
          entry = %{watcher_pid: watcher_pid, scope: scope}
          watchers = Map.put(state.watchers, project_root, entry)
          {:reply, :ok, %{state | watchers: watchers}}

        {:error, reason} ->
          Logger.warning("[FileWatcher] Could not watch #{project_root}: #{inspect(reason)}")
          {:reply, :ok, state}
      end
    end
  end

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

        relative_paths =
          paths
          |> Enum.map(&Path.relative_to(&1, project_root))
          |> Enum.to_list()

        try do
          start = System.monotonic_time(:millisecond)
          changed_components = DirtyTracker.mark_files_changed(scope, relative_paths)
          dirty_ms = System.monotonic_time(:millisecond) - start

          Enum.each(changed_components, fn component ->
            RequirementsSync.recalculate_component_requirements(scope, component)
          end)

          if changed_components != [] do
            status_ms = rewrite_status_files(scope)
            total_ms = System.monotonic_time(:millisecond) - start

            Logger.info(
              "[FileWatcher] Processed #{length(relative_paths)} file(s) → " <>
                "#{length(changed_components)} component(s) in #{total_ms}ms " <>
                "(dirty: #{dirty_ms}ms, requirements: #{total_ms - dirty_ms - status_ms}ms, status: #{status_ms}ms)"
            )
          end
        rescue
          e ->
            Logger.error(
              "[FileWatcher] Error processing file changes for #{project_root}: #{Exception.message(e)}"
            )
        end
    end
  end

  defp rewrite_status_files(scope) do
    start = System.monotonic_time(:millisecond)

    components =
      Components.list_components_with_dependencies(scope)
      |> HierarchicalTree.enrich()

    root_components = Enum.filter(components, &is_nil(&1.parent_component_id))

    stories =
      case Stories.list_project_stories(scope) do
        {:ok, s} -> CodeMySpec.Repo.preload(s, [:requirements, :component])
        _ -> []
      end

    project = CodeMySpec.Repo.preload(scope.active_project, :requirements)

    StatusWriter.write_status_files(root_components, stories, project, scope.environment)

    System.monotonic_time(:millisecond) - start
  end

  defp find_root_by_watcher(watcher_pid, watchers) do
    Enum.find_value(watchers, fn {root, %{watcher_pid: pid}} ->
      if pid == watcher_pid, do: root
    end)
  end
end
