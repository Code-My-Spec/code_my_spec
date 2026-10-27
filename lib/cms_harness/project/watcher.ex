defmodule CmsHarness.Project.Watcher do
  @moduledoc """
  One project's filesystem watcher.

  A child under each project's own supervisor, so one project's crash does not
  stop watching for the others.

  ## It stops watching when the harness is disconnected

  A disconnect stops the underlying watcher entirely; a rejoin starts a fresh
  one and a full rescan, which recovers whatever changed meanwhile (the
  manifest describes the working copy now). It starts paused for the same
  reason.

  See knowledge/harness/channel, "File watching".
  """

  use GenServer

  require Logger

  alias CmsHarness.Channel
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Paths

  # The scanner's directory sync roots. Root-level sync files (`mix.exs`,
  # `CLAUDE.md`, `.credo.exs`) are not watched — that would mean watching
  # `deps/` and `_build/` — and are picked up by the join sync or the next one.
  @watched_subdirs ["lib", "test", Paths.base_dir()]

  # There is deliberately no sync on a timer; events are the only trigger, and
  # the liveness check only logs.
  # See knowledge/harness/channel, "File watching".

  # Events are coalesced into one scan: long enough to absorb a multi-file
  # write, short enough that the next stop hook sees the result.
  @default_debounce_ms 2_000

  defp debounce_ms,
    do: Application.get_env(:code_my_spec, :harness_watch_debounce_ms, @default_debounce_ms)

  # How long a stream can deliver nothing before it is worth a log line; long
  # enough that an idle project does not fire it every cycle.
  @default_liveness_check_ms :timer.minutes(5)

  defp liveness_check_ms,
    do: Application.get_env(:code_my_spec, :harness_watch_liveness_ms, @default_liveness_check_ms)

  defstruct [
    :project,
    :fs_pid,
    :timer,
    :liveness_timer,
    :last_activity_at,
    watching?: false,
    quiet_logged?: false
  ]

  # --- Client API ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    GenServer.start_link(__MODULE__, project, name: via(project.root))
  end

  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:watcher, root}}}

  @doc "Start watching. Called by the channel client when it joins."
  @spec resume(String.t()) :: :ok
  # Synchronous: the post-join rescan must read the disk *after* the event
  # stream exists, or a write between the two is caught by neither.
  # `start_watching/1` does not call the channel client, so this cannot deadlock.
  def resume(root), do: call(root, :resume)

  @doc "Stop watching. Called by the channel client when the connection goes."
  @spec pause(String.t()) :: :ok
  def pause(root), do: cast(root, :pause)

  @doc "Whether this project is being watched right now."
  @spec watching?(String.t()) :: boolean()
  def watching?(root) do
    case Registry.lookup(CmsHarness.Registry, {:watcher, root}) do
      [{pid, _}] -> GenServer.call(pid, :watching?, 5_000)
      [] -> false
    end
  catch
    :exit, _ -> false
  end

  defp cast(root, message) do
    case Registry.lookup(CmsHarness.Registry, {:watcher, root}) do
      [{pid, _}] -> GenServer.cast(pid, message)
      [] -> :ok
    end
  end

  # A project with no watcher is not an error — nothing is being watched, which
  # is the state the caller wanted.
  defp call(root, message) do
    case Registry.lookup(CmsHarness.Registry, {:watcher, root}) do
      [{pid, _}] -> GenServer.call(pid, message)
      [] -> :ok
    end
  end

  # --- Callbacks ---

  @impl true
  def init(project) do
    # Paused. The channel client resumes it on join; if the channel is already
    # joined (this process restarted on its own) it asks.
    {:ok, %__MODULE__{project: project}, {:continue, :check_connection}}
  end

  @impl true
  def handle_continue(:check_connection, state) do
    if Channel.connected?(state.project.root) do
      {:noreply, start_watching(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:pause, %{watching?: false} = state), do: {:noreply, state}

  def handle_cast(:pause, state) do
    Logger.warning(
      "[CmsHarness] stopped watching #{state.project.root} — the harness is not connected " <>
        "to the CodeMySpec server. File changes are not being recorded. Watching resumes, " <>
        "with a full rescan, when it reconnects."
    )

    {:noreply, stop_watching(state)}
  end

  @impl true
  def handle_call(:resume, _from, %{watching?: true} = state), do: {:reply, :ok, state}
  def handle_call(:resume, _from, state), do: {:reply, :ok, start_watching(state)}

  def handle_call(:watching?, _from, state), do: {:reply, state.watching?, state}

  @impl true
  def handle_info({:file_event, pid, {path, events}}, %{fs_pid: pid} = state) do
    # Any event proves the stream is alive, whether or not it is worth a sync.
    state = mark_alive(state)

    if lost_events?(events) or (relevant?(events) and not ignored?(state.project.root, path)) do
      {:noreply, schedule_sync(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, pid, :stop}, %{fs_pid: pid} = state) do
    Logger.warning(
      "[CmsHarness] the filesystem watcher for #{state.project.root} stopped on its own"
    )

    {:noreply, %{state | fs_pid: nil, watching?: false}}
  end

  def handle_info(:sync, state) do
    Channel.request_sync(state.project.root)
    {:noreply, %{state | timer: nil}}
  end

  # A timer message from older code, which can outlive a hot upgrade.
  def handle_info(:resync, state) do
    {:noreply, state}
  end

  def handle_info(:liveness_check, %{watching?: false} = state), do: {:noreply, state}

  def handle_info(:liveness_check, state) do
    quiet_ms = System.monotonic_time(:millisecond) - state.last_activity_at

    state =
      if quiet_ms >= liveness_check_ms() and not state.quiet_logged? do
        Logger.warning(
          "[CmsHarness] #{state.project.root} has been watching? for #{div(quiet_ms, 1000)}s " <>
            "with no filesystem events delivered — the stream may be silently dead rather " <>
            "than the project being quiet. Restarting it does not reliably help (see issue " <>
            "aac6356e); check whether fseventsd (or the platform equivalent) is degraded."
        )

        %{state | quiet_logged?: true}
      else
        state
      end

    {:noreply, schedule_liveness_check(state)}
  end

  # A file event from a pid this process is not tracking: what a FileSystem
  # restarted underneath us looks like. Logged so a broken stream is visible.
  def handle_info({:file_event, other_pid, _payload}, state) do
    Logger.warning(
      "[CmsHarness] file event from #{inspect(other_pid)}, but this watcher is " <>
        "following #{inspect(state.fs_pid)} — ignoring it. Events are the only sync " <>
        "trigger, so nothing syncs until the watcher delivers again."
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Private ---

  defp start_watching(state) do
    dirs =
      @watched_subdirs
      |> Enum.map(&Path.join(state.project.root, &1))
      |> Enum.filter(&File.dir?/1)

    case dirs do
      [] ->
        Logger.warning(
          "[CmsHarness] nothing to watch under #{state.project.root} — no lib/, test/ or " <>
            "#{Paths.base_dir()}/. Is this the right working directory?"
        )

        state

      dirs ->
        options =
          Application.get_env(:code_my_spec, :harness_watch_options, [])
          |> Keyword.merge(dirs: dirs)

        {:ok, pid} = FileSystem.start_link(options)
        FileSystem.subscribe(pid)
        Logger.info("[CmsHarness] watching #{state.project.root}: #{Enum.join(dirs, ", ")}")

        %{state | fs_pid: pid, watching?: true}
        |> mark_alive()
        |> schedule_liveness_check()
    end
  end

  defp stop_watching(%{fs_pid: nil} = state), do: %{state | watching?: false}

  defp stop_watching(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.liveness_timer, do: Process.cancel_timer(state.liveness_timer)
    # Unlink before shutdown so the worker's exit does not stop this watcher.
    # A normal exit would leave its linked backend running after fixture cleanup.
    Process.unlink(state.fs_pid)
    GenServer.stop(state.fs_pid, :shutdown)
    %{state | fs_pid: nil, timer: nil, liveness_timer: nil, watching?: false}
  end

  # Resets `quiet_logged?`, which tracks whether this quiet stretch has been
  # reported.
  defp mark_alive(state) do
    %{state | last_activity_at: System.monotonic_time(:millisecond), quiet_logged?: false}
  end

  defp schedule_liveness_check(state) do
    if state.liveness_timer, do: Process.cancel_timer(state.liveness_timer)
    %{state | liveness_timer: Process.send_after(self(), :liveness_check, liveness_check_ms())}
  end

  defp schedule_sync(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sync, debounce_ms())}
  end

  # FSEvents reports these when it cannot account for every path change.
  # A complete scan is required even if the reported path is ignored.
  defp lost_events?(events),
    do: Enum.any?(events, &(&1 in [:mustscansubdirs, :userdropped, :kerneldropped]))

  defp relevant?(events),
    do: Enum.any?(events, &(&1 in [:modified, :created, :removed, :deleted, :renamed]))

  # Screened with the scanner's own rule, so what is watched and what is
  # scanned cannot drift apart.
  defp ignored?(root, abs_path) do
    abs_path
    |> Path.relative_to(root)
    |> Scanner.ignored_path?()
  end
end
