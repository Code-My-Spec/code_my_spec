defmodule CodeMySpec.RunGuard do
  @moduledoc """
  Keeps test and spex runs from outliving whatever started them (issue bee745a0).

  A run is an OS process group launched through a port. When its owner goes away
  (a killed task, a harness restart) the port closes but a `mix test` child does
  not notice, and runs on at full CPU, reparented to pid 1. Two such runs held
  the box at load 20 for hours.

  This is a watcher over the machine's ports, not a wrapper around any one
  caller, so every path that starts a run is covered:

    * **Pid log.** A watched command is logged with its OS pid once it has run
      for a poll interval, and again when it ends or is reaped. Quick commands
      (`git status`) never appear.
    * **Orphans.** A watched group whose port is gone while the group still runs
      is reaped: TERM, then KILL.
    * **Ceiling.** A run past `max_run_ms` is reaped, whoever owns it.
    * **Shutdown.** The groups it is tracking are killed when it terminates.
    * **Restart.** Each tracked group is also written to
      `<state dir>/runs/<beam pid>/<os pid>`. A BEAM killed outright cannot
      clean up after itself, so the next one sweeps the directories of BEAMs that
      are no longer alive.

  Only commands matching the watch pattern are tracked (test, spex and analyzer
  runs), so the long-lived app instances and tunnels a harness starts are left
  alone.
  """

  use GenServer
  use Boundary, top_level?: true, deps: [CodeMySpec.Paths, CodeMySpec.DurableRun], exports: :all

  require Logger

  alias CodeMySpec.DurableRun
  alias CodeMySpec.Paths

  @poll_ms 1_000
  @kill_grace_ms 2_000
  @max_run_ms :timer.minutes(90)
  @watch ~r/(?:^|[\s\/])(?:mix\s+(?:test|cms\.spex|spex|credo|compile)|just\s+(?:spex|test|exunit|credo|compile|check))\b/

  def start_link(opts \\ []) do
    # Process groups, `/bin/ps` and `/bin/kill` are Unix; on Windows the first
    # sweep raised and took the harness supervisor down with it.
    if match?({:win32, _}, :os.type()) do
      Logger.warning("[RunGuard] not running on Windows: test runs are not reaped here")
      :ignore
    else
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end
  end

  @doc "Look at the machine's ports now, instead of waiting for the next poll."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 15_000)

  @doc "The OS pids currently tracked."
  def tracked(server \\ __MODULE__), do: GenServer.call(server, :tracked)

  @doc "Where the groups of this BEAM, and of earlier ones, are recorded."
  def runs_dir, do: Path.join(Path.expand(Paths.local_state_dir()), "runs")

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    opts = Keyword.merge(Application.get_env(:code_my_spec, __MODULE__, []), opts)

    state = %{
      runs: %{},
      ignored: MapSet.new(),
      watch: Keyword.get(opts, :watch, @watch),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      max_run_ms: Keyword.get(opts, :max_run_ms, @max_run_ms),
      kill_grace_ms: Keyword.get(opts, :kill_grace_ms, @kill_grace_ms),
      dir: Keyword.get(opts, :dir, runs_dir())
    }

    sweep(state.dir, state.watch, state.kill_grace_ms)
    File.mkdir_p(own_dir(state))
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, poll(state)}
  def handle_call(:tracked, _from, state), do: {:reply, Map.keys(state.runs), state}

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.runs, fn {pid, run} ->
      unless DurableRun.protected_pid?(pid) do
        Logger.warning("[RunGuard] shutting down: killing os_pid=#{pid} (#{run.command})")
        kill_group(pid, 0)
      end

      # The manifest owns a protected run after this harness exits.
      if not group_alive?(pid) or DurableRun.protected_pid?(pid),
        do: File.rm(record_path(state, pid))
    end)

    File.rmdir(own_dir(state))
    :ok
  end

  defp schedule(%{poll_ms: :infinity}), do: :ok
  defp schedule(%{poll_ms: ms}), do: Process.send_after(self(), :poll, ms)

  defp poll(state) do
    present = port_pids()
    state |> advance_kills() |> start_kills(present) |> adopt(present)
  end

  defp port_pids do
    for port <- Port.list(),
        {:os_pid, pid} <- [Port.info(port, :os_pid)],
        is_integer(pid) and pid > 1,
        into: MapSet.new(),
        do: pid
  end

  defp adopt(state, present) do
    fresh =
      present
      |> MapSet.difference(MapSet.new(Map.keys(state.runs)))
      |> Enum.reject(&(&1 in state.ignored))

    Enum.reduce(fresh, %{state | ignored: MapSet.intersection(state.ignored, present)}, fn pid,
                                                                                           acc ->
      command = command_of(pid)

      if is_binary(command) and Regex.match?(acc.watch, command),
        do: track(acc, pid, command),
        else: %{acc | ignored: MapSet.put(acc.ignored, pid)}
    end)
  end

  defp track(state, pid, command) do
    Logger.info("[RunGuard] os_pid=#{pid} running: #{command}")
    File.write(record_path(state, pid), command)

    put_in(state.runs[pid], %{
      command: command,
      started: System.monotonic_time(:millisecond),
      kill: nil
    })
  end

  # A run leaves tracking, and its record is removed, only once its group is
  # confirmed gone (issue 4e1918aa). A kill is two steps with a pause between,
  # and a harness that restarts in the pause must leave the record behind for
  # the next instance's boot sweep to finish; dropping it first lost the run.
  #
  # Deciding to kill: the port is gone while the group still runs (it lost its
  # owner), or the run is over the ceiling. A run that ended is simply done.
  defp start_kills(state, present) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.runs, state, fn
      {_pid, %{kill: kill}}, acc when not is_nil(kill) ->
        acc

      {pid, run}, acc ->
        cond do
          not MapSet.member?(present, pid) and DurableRun.protected_pid?(pid) ->
            Logger.info("[RunGuard] os_pid=#{pid} continues under its durable manifest")
            drop(acc, pid)

          not MapSet.member?(present, pid) and group_alive?(pid) ->
            Logger.error(
              "[RunGuard] os_pid=#{pid} lost its owner and is still running — killing it (#{run.command})"
            )

            begin_kill(acc, pid, now)

          not MapSet.member?(present, pid) ->
            Logger.info("[RunGuard] os_pid=#{pid} finished (#{run.command})")
            drop(acc, pid)

          now - run.started >= acc.max_run_ms ->
            Logger.error(
              "[RunGuard] os_pid=#{pid} exceeded #{acc.max_run_ms}ms — killing it (#{run.command})"
            )

            begin_kill(acc, pid, now)

          true ->
            acc
        end
    end)
  end

  # TERM now; KILL once the pause has passed, on a later poll; the run stays
  # tracked, with its record, until the group is gone.
  defp begin_kill(state, pid, now) do
    signal_group("-TERM", pid)
    put_in(state.runs[pid].kill, %{kill_at: now + state.kill_grace_ms, killed?: false})
  end

  defp advance_kills(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.runs, state, fn
      {pid, %{kill: %{} = kill} = run}, acc ->
        cond do
          not group_alive?(pid) ->
            Logger.info("[RunGuard] os_pid=#{pid} is gone (#{run.command})")
            drop(acc, pid)

          now >= kill.kill_at ->
            signal_group("-KILL", pid)
            put_in(acc.runs[pid].kill, %{kill | killed?: true})

          true ->
            acc
        end

      _tracked, acc ->
        acc
    end)
  end

  defp drop(state, pid) do
    File.rm(record_path(state, pid))
    %{state | runs: Map.delete(state.runs, pid)}
  end

  # --- earlier BEAMs ---

  defp sweep(dir, watch, grace) do
    case File.ls(dir) do
      {:ok, beams} ->
        beams
        |> Enum.reject(&(&1 == System.pid()))
        |> Enum.each(&sweep_beam(dir, &1, watch, grace))

      {:error, _} ->
        :ok
    end
  end

  defp sweep_beam(dir, beam, watch, grace) do
    path = Path.join(dir, beam)

    if beam_alive?(beam) do
      :ok
    else
      Enum.each(recorded_runs(path), &sweep_run(&1, path, beam, watch, grace))
      File.rmdir(path)
    end
  end

  defp sweep_run({pid, recorded}, path, beam, watch, grace) do
    protected? = DurableRun.protected_pid?(pid)

    if still_watched?(pid, watch) and not protected? do
      Logger.error(
        "[RunGuard] os_pid=#{pid} was left by BEAM #{beam}, which is gone — killing it (#{recorded})"
      )

      kill_group(pid, grace)
    end

    # Kept if the group survived: the next instance tries again.
    if not group_alive?(pid) or protected?, do: File.rm(Path.join(path, Integer.to_string(pid)))
  end

  # The pid may have been reused since: only a process that still looks like a
  # watched run is touched.
  defp still_watched?(pid, watch) do
    command = command_of(pid)
    is_binary(command) and Regex.match?(watch, command)
  end

  defp recorded_runs(path) do
    for file <- ls(path),
        {pid, ""} <- [Integer.parse(file)],
        {:ok, command} <- [File.read(Path.join(path, file))],
        do: {pid, command}
  end

  # A BEAM's directory can go between listing its parent and listing it.
  defp ls(path) do
    case File.ls(path) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  # --- the OS ---

  defp own_dir(state), do: Path.join(state.dir, System.pid())
  defp record_path(state, pid), do: Path.join(own_dir(state), Integer.to_string(pid))

  defp command_of(pid) do
    case System.cmd("/bin/ps", ["-o", "command=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp beam_alive?(beam),
    do: match?({_, 0}, System.cmd("/bin/kill", ["-0", beam], stderr_to_stdout: true))

  defp group_alive?(pid),
    do: match?({_, 0}, System.cmd("/bin/kill", ["-0", "--", "-#{pid}"], stderr_to_stdout: true))

  defp signal_group(signal, pid),
    do: System.cmd("/bin/kill", [signal, "--", "-#{pid}"], stderr_to_stdout: true)

  # Both steps in order, for callers that are about to go away themselves.
  defp kill_group(pid, grace) do
    signal_group("-TERM", pid)
    Process.sleep(grace)
    signal_group("-KILL", pid)
    :ok
  end
end
