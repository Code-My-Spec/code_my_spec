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
     instead of projecting it.) On a detected change the lock is parsed
     and recorded via `Dependencies`, then the packages whose docs are
     not yet projected at their recorded version are projected —
     retrying a bounded number of times for source that has not been
     unpacked yet, and reporting whatever never appears.

  The recording step is what removed the old race. Projection used to
  wait out a fixed ten-second window and hope `mix deps.get` had
  finished unpacking; a slower machine lost that bet silently, embedding
  a half-unpacked tree and reporting success. The lock, unlike the tree,
  is complete the moment it is written, so recording it needs no window
  at all — and projection driven from recorded state has an end state
  (`Dependencies.pending/1` empty) that can be waited on and asserted.
  """
  use GenServer
  require Logger

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Environments
  alias CodeMySpec.Leases
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

  # Coalesce a burst of lock rewrites into one pass. This is a debounce, not a
  # settle window: it is not waiting for `mix deps.get` to finish, it is waiting
  # to stop being told the same thing.
  @lock_debounce_ms 1_000

  # How long to wait before re-attempting packages whose source has not appeared
  # in `deps/` yet, and how many times. This is what replaced a single blind
  # ten-second guess at how long an unpack takes: the common case finishes on
  # the first pass because the lock is written before unpacking starts, and a
  # slow one gets four passes over ~20s instead of one deadline it can miss.
  #
  # Bounded rather than indefinite, because a package can be legitimately absent
  # forever — an `only: :dev` dependency in a prod checkout is in the lock and
  # will never be in `deps/`. What stays missing is reported, not retried into
  # eternity.
  @projection_retry_ms 5_000
  @max_projection_passes 4

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

        Logger.info(
          "[FileWatcher] Boot embed pass complete root=#{root} knowledge_ms=#{knowledge_ms}"
        )
      end)
    end)

    # HexDocProjector recursively globs deps/<pkg>/lib/**/*.ex for EVERY package
    # in EVERY watched project — millions of File.ls calls, all serialized
    # through the single global :file_server_2. Doing that for all projects at
    # boot wedged the file server long enough that /mcp requests (which need the
    # file server) timed out — fatal under launchd, where the service comes up
    # with the full project set. Deps hex-docs are re-projected on `mix.lock`
    # changes by the poller, and per-project on demand; the boot-time full scan
    # is redundant and is deliberately dropped. See project_codemyspec_independence.
    :ok
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

  # Watching a project is how a harness starts owning its Files rows, so this is
  # where the lease is claimed. A second harness on the same project does not
  # get a degraded mode — it does not watch at all, because the damage is not in
  # reading, it is in syncing a second working copy into one set of rows and
  # deleting whatever the first one wrote.
  defp do_watch(project_root, scope, state) do
    case claim_project(project_root, scope) do
      :ok ->
        do_watch_claimed(project_root, scope, state)

      {:error, {:held_by, holder}} ->
        Logger.error(
          "[FileWatcher] not watching #{project_root} — #{holder} already holds this " <>
            "project. Two harnesses syncing one project overwrite each other's files and " <>
            "produce a requirement graph that matches neither checkout. Stop that harness; " <>
            "its lease frees the moment it exits."
        )

        {:noreply, state}
    end
  end

  defp claim_project(project_root, scope) do
    Leases.acquire(scope, Leases.describe(project_root))
  rescue
    # A project with no id in scope, or a repo that is not up yet. The lease is
    # a guard against a specific kind of corruption, not a precondition for the
    # watcher existing — failing to evaluate it must not stop a lone harness
    # from working.
    exception ->
      Logger.warning(
        "[FileWatcher] could not evaluate the project lease for #{project_root} " <>
          "(#{Exception.message(exception)}) — watching anyway"
      )

      :ok
  end

  defp do_watch_claimed(project_root, scope, state) do
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

  def handle_info({:run_hex_sync, project_root, pass}, state) do
    state = %{state | hex_sync_timers: Map.delete(state.hex_sync_timers, project_root)}

    case Map.fetch(state.watchers, project_root) do
      {:ok, %{scope: scope}} -> run_projection_pass(scope, project_root, pass)
      :error -> :ok
    end

    {:noreply, state}
  end

  # Reported by the task so the server, not the task, owns the retry decision.
  def handle_info({:hex_pass_done, project_root, pass, missing}, state) do
    cond do
      missing == [] ->
        {:noreply, state}

      pass < @max_projection_passes ->
        Logger.info(
          "[FileWatcher] #{length(missing)} package(s) not unpacked yet for #{project_root}, " <>
            "pass #{pass}/#{@max_projection_passes}"
        )

        {:noreply, schedule_hex_sync(state, project_root, pass + 1, @projection_retry_ms)}

      true ->
        # Out of retries. Say which packages contributed no documentation and
        # settle them, rather than leaving the project permanently pending or —
        # worse — quietly converging as though they had been read.
        case Map.fetch(state.watchers, project_root) do
          {:ok, %{scope: scope}} ->
            settled = HexDocProjector.settle_missing(scope)

            Logger.warning(
              "[FileWatcher] no source found in deps/ for #{Enum.join(settled, ", ")} " <>
                "(#{project_root}) — these contribute no documentation. Expected for " <>
                "environment-gated deps; otherwise `mix deps.get` may not have run."
            )

          :error ->
            :ok
        end

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Record what the lock says, then project whatever has landed on disk.
  #
  # The order matters and is the whole point: the lock is complete the moment it
  # is written, so recording it never has to wait for anything. Only projection
  # depends on `mix deps.get` having unpacked source, and that is the part that
  # retries.
  defp run_projection_pass(scope, project_root, pass) do
    server = self()

    Task.start(fn ->
      try do
        record_lock(scope, project_root)

        # Before projecting, clear docs for anything that left the lock. Keyed
        # on the recorded set rather than on the removal event, so a removal
        # that happened while this was down still converges.
        HexDocProjector.drop_unrecorded(scope)

        %{projected: projected, missing: missing} = HexDocProjector.project_pending(scope)

        if projected != [] do
          Logger.info(
            "[FileWatcher] projected docs for #{length(projected)} package(s) in #{project_root}"
          )
        end

        send(server, {:hex_pass_done, project_root, pass, missing})
      rescue
        e ->
          Logger.error(
            "[FileWatcher] Hex doc projector failed for #{project_root}: #{Exception.message(e)}"
          )
      end
    end)
  end

  defp record_lock(scope, project_root) do
    env = scope_environment(scope)

    with {:ok, contents} <- Environments.read_file(env, "mix.lock"),
         {:ok, %{recorded: recorded, removed: removed}} <-
           Dependencies.record_lockfile(scope, contents) do
      Logger.info(
        "[FileWatcher] recorded #{recorded} dependencies (#{removed} removed) for #{project_root}"
      )
    else
      {:error, :unparseable} ->
        # Loud, and deliberately non-destructive: an unreadable lock says
        # nothing about what a project depends on, so it must not be allowed to
        # say "nothing". The previously recorded set stands.
        Logger.warning(
          "[FileWatcher] could not parse mix.lock for #{project_root} — " <>
            "keeping the previously recorded dependency set"
        )

      {:error, reason} ->
        Logger.warning(
          "[FileWatcher] could not read mix.lock for #{project_root}: #{inspect(reason)}"
        )
    end
  end

  defp scope_environment(%Scope{environment: %Environments.Environment{} = env}), do: env

  defp scope_environment(%Scope{cwd: cwd}),
    do: Environments.Environment.new(:local, cwd || File.cwd!())

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

  defp schedule_hex_sync(state, project_root, pass \\ 1, delay \\ @lock_debounce_ms) do
    if existing = Map.get(state.hex_sync_timers, project_root) do
      Process.cancel_timer(existing)
    end

    timer_ref = Process.send_after(self(), {:run_hex_sync, project_root, pass}, delay)
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

  # "Every project with a local_path" was a safe definition of "mine" only
  # while the database was per-machine: the rows in a local SQLite file were
  # by construction this machine's projects. On a shared database it means
  # every project anyone has ever linked, and a sprite booting against
  # centralized data starts watchers for all of them, pointed at directories
  # that belong to someone else's laptop.
  #
  # A sprite has exactly one working copy, so it says which project it is.
  # Absent that, behaviour is unchanged for a desktop install.
  #
  # Note the `File.dir?` guard below would mask this in a container (none of
  # those paths exist there, so nothing would start) — but that is an accident
  # of the paths being absent, not scoping. The moment a host path happened to
  # exist inside the container, it would be watched.
  defp watch_all_linked_projects(state) do
    Enum.reduce(watchable_projects(), state.watchers, &maybe_add_watcher/2)
  end

  # Returns {project, root} pairs. The root is a separate value because the two
  # deployments answer "where is this project on disk?" differently: a desktop
  # reads the column it wrote itself, while a sprite cloned to a path it chose
  # at runtime and the shared column still describes somebody else's laptop.
  defp watchable_projects do
    import Ecto.Query

    alias CodeMySpec.Projects.Project

    case Application.get_env(:code_my_spec, :project_id) do
      nil ->
        Project
        |> where([p], not is_nil(p.local_path))
        |> CodeMySpec.Repo.all()
        |> Enum.map(&{&1, &1.local_path})

      project_id ->
        case CodeMySpec.Repo.get(Project, project_id) do
          nil -> []
          project -> [{project, sprite_root(project)}]
        end
    end
  end

  defp sprite_root(project) do
    Application.get_env(:code_my_spec, :mcp_working_dir) || project.local_path
  end

  defp maybe_add_watcher({project, root}, watchers) do
    cond do
      is_nil(root) -> watchers
      Map.has_key?(watchers, root) -> watchers
      not File.dir?(root) -> watchers
      true -> add_watcher_for_project(project, root, watchers)
    end
  end

  defp add_watcher_for_project(project, root, watchers) do
    with {:ok, scope} <- Scope.for_local_project(project, root),
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
