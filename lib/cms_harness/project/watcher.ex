defmodule CmsHarness.Project.Watcher do
  @moduledoc """
  One project's filesystem watcher.

  Per project, not per harness. The server's `FileWatcherServer` is a singleton
  managing every project at once, so one project's crash stops watching for all
  of them; a child under each project's own supervisor is what fixes that, and
  it is the whole reason the tree has a `DynamicSupervisor` in it.

  ## It stops watching when the harness is disconnected

  This is the point of the module, not a detail of it. A watcher that keeps
  running while the channel is down accumulates events it cannot deliver, and
  events it cannot deliver are events it will not remember — the backlog is
  lost silently and the server's picture of the project stays wrong with
  nothing to indicate it.

  So a disconnect **stops the underlying watcher entirely**, and a rejoin
  starts a fresh one *and* a full rescan. The rescan is what recovers the gap:
  the manifest is a statement about the working copy now, so it does not matter
  which events were missed while it was down.

  It starts paused for the same reason — there is nowhere to send anything
  until the channel says otherwise.
  """

  use GenServer

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Paths

  # The scanner's sync roots that are directories. `mix.exs`, `CLAUDE.md` and
  # `.credo.exs` are sync roots too, but watching the project root to catch
  # three rarely-edited files means watching `deps/` and `_build/` on every
  # recompile. They are picked up by the sync that runs on join and by the next
  # sync any other change triggers.
  @watched_subdirs ["lib", "test", Paths.base_dir()]

  # A full sync on a timer, regardless of what the watcher has to say.
  #
  # Drill 8 spent its last forty-five minutes writing files nobody saw. The
  # watcher process was alive, `watching?` was true, `inotifywait` was running
  # and watching the right directories — and no event arrived, so no sync ran,
  # so the graph froze while the agent kept working against it. A single
  # `touch` hours later reconciled all 165 files at once: nothing had been
  # lost, nothing had been looked at.
  #
  # The root cause of the missed events is still unproven. This does not depend
  # on knowing it. An event stream with nothing checking it is a liveness claim
  # backed by nothing, and the cost of being wrong is an agent working blind for
  # as long as the run lasts. A floor turns "frozen until someone notices" into
  # "stale by at most this long".
  @resync_interval_ms 90_000

  # A single edit rarely arrives as a single event, and the only thing the
  # harness can send is a whole manifest, so events are coalesced into one
  # scan. Long enough to absorb a multi-file write, short enough that the next
  # stop hook sees the result.
  @default_debounce_ms 2_000

  defp debounce_ms,
    do: Application.get_env(:code_my_spec, :harness_watch_debounce_ms, @default_debounce_ms)

  defstruct [:project, :fs_pid, :timer, watching?: false]

  # --- Client API ---

  def start_link(opts) do
    project = Keyword.fetch!(opts, :project)
    GenServer.start_link(__MODULE__, project, name: via(project.root))
  end

  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:watcher, root}}}

  @doc "Start watching. Called by the channel client when it joins."
  @spec resume(String.t()) :: :ok
  # Synchronous, and that is the point. The rescan that follows a join is what
  # recovers whatever changed while the harness was disconnected, so it has to
  # read the disk *after* the event stream exists — otherwise a write landing
  # between the two is caught by neither, and a file missed that way is
  # indistinguishable from a file that never changed.
  #
  # A cast made the ordering a race. `start_watching/1` does not call back into
  # the channel client, so waiting here cannot deadlock.
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
    # Paused. The channel client resumes it on join — and if the channel is
    # already joined (this process restarted on its own) it asks, rather than
    # assuming either way.
    schedule_resync()

    {:ok, %__MODULE__{project: project}, {:continue, :check_connection}}
  end

  @impl true
  def handle_continue(:check_connection, state) do
    if ChannelClient.connected?(state.project.root) do
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
    if relevant?(events) and not ignored?(state.project.root, path) do
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
    ChannelClient.request_sync(state.project.root)
    {:noreply, %{state | timer: nil}}
  end

  # Always reschedules, even while paused: a paused watcher that is later
  # resumed should not also have lost its floor.
  def handle_info(:resync, state) do
    schedule_resync()

    if state.watching? do
      ChannelClient.request_sync(state.project.root)
    end

    {:noreply, state}
  end

  # A file event from a pid this process is not tracking used to fall into the
  # catch-all below and vanish, leaving `watching?: true` and nothing arriving —
  # indistinguishable from a project where nothing changed. If FileSystem is
  # ever restarted underneath us, this is what it looks like, so say so.
  def handle_info({:file_event, other_pid, _payload}, state) do
    Logger.warning(
      "[CmsHarness] file event from #{inspect(other_pid)}, but this watcher is " <>
        "following #{inspect(state.fs_pid)} — ignoring it. Sync is running on its " <>
        "timer alone; the watcher is not delivering."
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
        {:ok, pid} = FileSystem.start_link(dirs: dirs)
        FileSystem.subscribe(pid)
        Logger.info("[CmsHarness] watching #{state.project.root}: #{Enum.join(dirs, ", ")}")
        %{state | fs_pid: pid, watching?: true}
    end
  end

  defp stop_watching(%{fs_pid: nil} = state), do: %{state | watching?: false}

  defp stop_watching(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    # Unlinked before stopping so a normal shutdown of the watcher is not an
    # exit signal to this process.
    Process.unlink(state.fs_pid)
    GenServer.stop(state.fs_pid, :normal)
    %{state | fs_pid: nil, timer: nil, watching?: false}
  end

  @doc "The sync floor, exposed so a test can hold it to a bound."
  def resync_interval_ms, do: @resync_interval_ms

  defp schedule_resync, do: Process.send_after(self(), :resync, @resync_interval_ms)

  defp schedule_sync(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sync, debounce_ms())}
  end

  defp relevant?(events),
    do: Enum.any?(events, &(&1 in [:modified, :created, :removed, :renamed]))

  # `_build/` under a watched root would be a recompile firehose; so would an
  # editor's own scratch files. Screened with the same rule the scanner uses,
  # so what is watched and what is scanned cannot drift apart.
  defp ignored?(root, abs_path) do
    abs_path
    |> Path.relative_to(root)
    |> Scanner.ignored_path?()
  end
end
