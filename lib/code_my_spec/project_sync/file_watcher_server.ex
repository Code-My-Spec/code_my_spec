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
  2. **`mix.lock` polling.** The hex doc projector reads dependency
     source from `deps/<package>/lib/**/*.ex`. That source only changes
     on real dep events (`mix deps.get`/`update`/`unlock`), which are
     exactly the events that rewrite `mix.lock` — so polling the lock's
     mtime is the causally correct signal at zero event volume. (We do
     NOT watch `deps/` via filesystem events: routing dep source through
     `FileSync.sync_path/3` would try to embed each dep file directly
     instead of projecting it.) On detected change we debounce a short
     settle window (`@lock_settle_delay_ms`) for the `mix deps.get`
     unpack to finish writing source, then run the projector.
  """
  use GenServer
  require Logger

  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL

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
  # projector. Lets the `mix deps.get` unpack finish writing source into
  # `deps/<package>/lib/` before we read it. No `mix deps.compile` wait
  # is needed anymore — projection reads source, not compiled BEAMs — so
  # this is far shorter than the old beam-era 90s. Mid-write reads still
  # no-op gracefully (unparseable source yields no module).
  @lock_settle_delay_ms 10_000

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
        run_boot_embed_pass(watchers)
        {:noreply, %{state | watchers: watchers, lock_mtimes: lock_mtimes}}

      attempts >= 10 ->
        Logger.error("[FileWatcher] Repo not ready after 10 attempts — skipping auto-watch")
        {:noreply, state}

      true ->
        Process.sleep(500)
        {:noreply, state, {:continue, {:scan_projects, attempts + 1}}}
    end
  end

  # One-shot at boot: re-embed bundled framework knowledge and project
  # hex docs for every watched project. After this point, ongoing dep
  # changes are caught by `mix.lock` polling; framework knowledge
  # changes only when the cms binary itself is replaced (which restarts
  # this GenServer and re-triggers this pass). Runs in a Task so a slow
  # projector doesn't hold up watcher startup.
  defp run_boot_embed_pass(watchers) do
    Enum.each(watchers, fn {root, %{scope: scope}} ->
      Task.start(fn ->
        Logger.info("[FileWatcher] Boot embed pass start root=#{root}")
        knowledge_start = System.monotonic_time(:millisecond)
        Embeddings.sync_framework_knowledge(scope)
        knowledge_ms = System.monotonic_time(:millisecond) - knowledge_start

        projector_start = System.monotonic_time(:millisecond)
        HexDocProjector.project(scope)
        projector_ms = System.monotonic_time(:millisecond) - projector_start

        Logger.info(
          "[FileWatcher] Boot embed pass complete root=#{root} knowledge_ms=#{knowledge_ms} projector_ms=#{projector_ms}"
        )
      end)
    end)
  end

  defp repo_ready? do
    match?({:ok, _}, SQL.query(CodeMySpec.Repo, "SELECT 1", [], timeout: 5_000))
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
        Sync.sync_path(scope, abs_path)
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
