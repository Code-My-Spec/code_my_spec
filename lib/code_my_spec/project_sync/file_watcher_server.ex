defmodule CodeMySpec.ProjectSync.FileWatcherServer do
  @moduledoc """
  Singleton GenServer that watches project directories for file changes.

  Auto-watches all linked projects on boot. New directories can also be
  registered via `ensure_watching/1`.

  On file change: classifies, validates, and upserts the individual file,
  then runs incremental ComponentSync for affected components.
  """
  use GenServer
  require Logger

  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Users.Scope

  @watched_subdirs [
    ".code_my_spec/spec",
    ".code_my_spec/rules",
    ".code_my_spec/qa",
    ".code_my_spec/architecture",
    ".code_my_spec/integrations",
    ".code_my_spec/tasks",
    "lib",
    "test"
  ]

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
    {:ok, %{watchers: %{}}, {:continue, :watch_linked_projects}}
  end

  @impl true
  def handle_continue(:watch_linked_projects, state) do
    watchers = watch_all_linked_projects(state)
    {:noreply, %{state | watchers: watchers}}
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
      process_file_event(watcher_pid, path, state.watchers)
    end

    {:noreply, state}
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

  defp process_file_event(watcher_pid, abs_path, watchers) do
    case find_root_by_watcher(watcher_pid, watchers) do
      nil ->
        :ok

      project_root ->
        %{scope: scope} = watchers[project_root]

        try do
          {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: project_root)

          if result.changed_path do
            FileComponentSync.sync_from_files(scope,
              base_dir: project_root,
              changed_paths: [result.changed_path]
            )
          end
        rescue
          e ->
            Logger.error("[FileWatcher] Error processing #{abs_path}: #{Exception.message(e)}")
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
