defmodule CodeMySpec.ProjectSync.FileWatcherServer do
  @moduledoc """
  Singleton GenServer that watches project directories for file changes
  and detects hex dep changes via `mix.lock` polling.

  Auto-watches all linked projects on boot. New directories can also be
  registered via `ensure_watching/1`.

  Two responsibilities:

  1. **File-event subscription** for the project subtrees in
     `@watched_subdirs` (specs, rules, code, etc). Events drive
     `FileSync.sync_path/3` for fingerprint-diff'd embedding refresh.
  2. **`mix.lock` polling.** Watching `_build/<env>/lib/*/ebin/*.beam`
     events flooded the watcher under normal `mix compile` activity —
     every BEAM gets rewritten on recompile even when source is
     unchanged. `mix.lock` only changes on real dep events
     (`mix deps.get`/`update`/`unlock`), so polling its mtime is the
     causally correct signal at zero event volume. On detected change
     we debounce a settle window (`@lock_settle_delay_ms`) for any
     follow-up `mix deps.compile` to finish, then run the hex doc
     projector for that project.
  """
  use GenServer
  require Logger

  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Users.Scope

  # Watched subtrees under each project root. Anything outside these
  # is invisible to the watcher. Doc dirs are here so embedding hooks
  # in `FileSync.sync_path/3` fire as soon as the agent writes new
  # content. `_build/` is intentionally absent — it's a recompile
  # firehose; deps changes are detected via mix.lock polling instead.
  @watched_subdirs [
    ".code_my_spec/spec",
    ".code_my_spec/rules",
    ".code_my_spec/qa",
    ".code_my_spec/architecture",
    ".code_my_spec/integrations",
    ".code_my_spec/tasks",
    ".code_my_spec/hex_docs",
    ".code_my_spec/knowledge",
    "lib",
    "test"
  ]

  # How often to stat each project's `mix.lock`. Cheap (one stat call
  # per project per tick), so 30s is generous. Lower bound = max
  # latency before we even notice a lock change.
  @lock_poll_interval_ms 30_000

  # After detecting a lock change, wait this long before running the
  # projector. Lets a `mix deps.compile` chain settle so we read
  # already-built BEAMs rather than mid-write ones. Mid-write reads
  # gracefully no-op (`Code.fetch_docs` returns `{:error, _}`), but
  # waiting avoids spurious empty projections.
  @lock_settle_delay_ms 90_000

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
    schedule_lock_poll()

    {:ok,
     %{
       watchers: %{},
       lock_mtimes: %{},
       hex_sync_timers: %{}
     }, {:continue, {:scan_projects, 0}}}
  end

  @impl true
  def handle_continue({:scan_projects, attempts}, state) do
    cond do
      repo_ready?() ->
        watchers = watch_all_linked_projects(state)
        lock_mtimes = snapshot_lock_mtimes(watchers)
        {:noreply, %{state | watchers: watchers, lock_mtimes: lock_mtimes}}

      attempts >= 10 ->
        Logger.error("[FileWatcher] Repo not ready after 10 attempts — skipping auto-watch")
        {:noreply, state}

      true ->
        Process.sleep(500)
        {:noreply, state, {:continue, {:scan_projects, attempts + 1}}}
    end
  end

  defp repo_ready? do
    match?(
      {:ok, _},
      Ecto.Adapters.SQL.query(CodeMySpec.Repo, "SELECT 1", [], timeout: 5_000)
    )
  end

  @impl true
  def handle_cast({:ensure_watching, project_root, scope}, state) do
    if Map.has_key?(state.watchers, project_root) do
      {:noreply, state}
    else
      do_watch(project_root, scope, state)
    end
  end

  defp do_watch(project_root, scope, state) do
    case start_watcher(project_root) do
      {:ok, watcher_pid} ->
        entry = %{watcher_pid: watcher_pid, scope: scope}
        watchers = Map.put(state.watchers, project_root, entry)
        lock_mtimes = put_lock_mtime(state.lock_mtimes, project_root)
        {:noreply, %{state | watchers: watchers, lock_mtimes: lock_mtimes}}

      {:error, reason} ->
        Logger.warning("[FileWatcher] Could not watch #{project_root}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp put_lock_mtime(lock_mtimes, project_root) do
    case lock_mtime(project_root) do
      nil -> lock_mtimes
      mtime -> Map.put(lock_mtimes, project_root, mtime)
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

  def handle_info(:poll_locks, state) do
    state = poll_locks(state)
    schedule_lock_poll()
    {:noreply, state}
  end

  def handle_info({:run_hex_sync, project_root}, state) do
    state = %{state | hex_sync_timers: Map.delete(state.hex_sync_timers, project_root)}

    case Map.fetch(state.watchers, project_root) do
      {:ok, %{scope: scope}} ->
        Logger.info("[FileWatcher] Running hex doc projector for #{project_root}")

        Task.start(fn ->
          try do
            HexDocProjector.project(scope)
          rescue
            e ->
              Logger.error(
                "[FileWatcher] Hex doc projector failed for #{project_root}: #{Exception.message(e)}"
              )
          end
        end)

      :error ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp schedule_lock_poll do
    Process.send_after(self(), :poll_locks, @lock_poll_interval_ms)
  end

  defp poll_locks(state) do
    Enum.reduce(state.watchers, state, fn {project_root, _entry}, acc ->
      poll_lock(acc, project_root)
    end)
  end

  defp poll_lock(state, project_root) do
    case lock_mtime(project_root) do
      nil -> state
      mtime -> apply_lock_mtime(state, project_root, mtime)
    end
  end

  defp apply_lock_mtime(state, project_root, mtime) do
    previous = Map.get(state.lock_mtimes, project_root)

    state
    |> maybe_schedule_hex_sync(project_root, previous, mtime)
    |> put_in([Access.key!(:lock_mtimes), project_root], mtime)
  end

  defp maybe_schedule_hex_sync(state, project_root, previous, mtime)
       when not is_nil(previous) and previous != mtime do
    Logger.info("[FileWatcher] mix.lock changed for #{project_root}, scheduling hex sync")
    schedule_hex_sync(state, project_root)
  end

  defp maybe_schedule_hex_sync(state, _project_root, _previous, _mtime), do: state

  defp schedule_hex_sync(state, project_root) do
    if existing = Map.get(state.hex_sync_timers, project_root) do
      Process.cancel_timer(existing)
    end

    timer_ref = Process.send_after(self(), {:run_hex_sync, project_root}, @lock_settle_delay_ms)
    %{state | hex_sync_timers: Map.put(state.hex_sync_timers, project_root, timer_ref)}
  end

  defp snapshot_lock_mtimes(watchers) do
    watchers
    |> Map.keys()
    |> Enum.reduce(%{}, fn project_root, acc ->
      case lock_mtime(project_root) do
        nil -> acc
        mtime -> Map.put(acc, project_root, mtime)
      end
    end)
  end

  defp lock_mtime(project_root) do
    case File.stat(Path.join(project_root, "mix.lock"), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

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
        rel_path = Path.relative_to(abs_path, project_root)

        try do
          sync_classified_path(scope, project_root, rel_path)
        rescue
          e ->
            Logger.error("[FileWatcher] Error processing #{abs_path}: #{Exception.message(e)}")
        end
    end
  end

  defp sync_classified_path(scope, project_root, rel_path) do
    abs_path = Path.join(project_root, rel_path)
    {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: project_root)

    # Component sync is only meaningful for files whose role drives a
    # component (spec, implementation, test, etc.). Doc-corpus files
    # like hex docs or project_knowledge would otherwise trigger an
    # empty-result query on every individual write.
    if result.changed_path && component_relevant_path?(result.changed_path) do
      FileComponentSync.sync_from_files(scope,
        base_dir: project_root,
        changed_paths: [result.changed_path]
      )
    end
  end

  defp component_relevant_path?(rel_path) do
    String.starts_with?(rel_path, "lib/") or
      String.starts_with?(rel_path, "test/") or
      String.starts_with?(rel_path, ".code_my_spec/spec/")
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

    Enum.reduce(projects, state.watchers, &maybe_add_watcher/2)
  end

  defp maybe_add_watcher(project, watchers) do
    root = project.local_path

    cond do
      Map.has_key?(watchers, root) -> watchers
      not File.dir?(root) -> watchers
      true -> add_watcher_for_project(project, root, watchers)
    end
  end

  defp add_watcher_for_project(project, root, watchers) do
    with {:ok, scope} <- Scope.for_local_project(project),
         {:ok, watcher_pid} <- start_watcher(root) do
      Logger.info("[FileWatcher] Auto-watching #{project.name} at #{root}")
      Map.put(watchers, root, %{watcher_pid: watcher_pid, scope: scope})
    else
      {:error, reason} ->
        Logger.warning("[FileWatcher] Could not watch #{root}: #{inspect(reason)}")
        watchers

      _ ->
        watchers
    end
  end
end
