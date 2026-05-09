defmodule CodeMySpecCli.Daemon do
  @moduledoc """
  Daemon lifecycle for the cms CLI binary: status / start / stop / logs.

  The binary is normally run as a background server. These helpers make
  that explicit so users can ask "is it up?" without greping lsof, and
  the SessionStart hook can call `cms start` as a one-liner instead of
  managing nohup/disown/wait loops itself.
  """

  @port 4003
  @health_url "http://localhost:#{@port}/health"
  @start_timeout_s 60
  @stop_timeout_s 20

  def cms_home, do: Path.expand("~/.codemyspec")
  def pid_file, do: Path.join(cms_home(), "cms.pid")
  def log_file, do: Path.join(cms_home(), "server.log")
  # Raw stdout/stderr from the daemonized cms binary (BEAM startup, IO.puts).
  # Application logs go through :logger to log_file/0 with rotation.
  def boot_log_file, do: Path.join(cms_home(), "server.boot.log")

  # --- status ---------------------------------------------------------------

  @doc """
  Probes the running server. Returns `{:running, info}` if /health responds,
  `:stopped` otherwise.
  """
  def status do
    if health_ok?() do
      {:running,
       %{
         version: version(),
         pid: read_pid(),
         port: @port,
         log: log_file()
       }}
    else
      :stopped
    end
  end

  def print_status do
    case status() do
      {:running, info} ->
        pid = info.pid || "?"
        IO.puts("cms v#{info.version}  ·  pid #{pid}  ·  port #{info.port}  ·  log #{info.log}")
        0

      :stopped ->
        IO.puts(:stderr, "cms: not running")

        case read_pid() do
          nil -> :ok
          stale -> IO.puts(:stderr, "(stale pid #{stale} in #{pid_file()})")
        end

        1
    end
  end

  # --- start ----------------------------------------------------------------

  @doc """
  Starts the server detached, waits for /health to respond.
  Idempotent — no-op if already running.
  """
  def start(cms_bin) do
    case status() do
      {:running, info} ->
        IO.puts("cms already running (pid #{info.pid || "?"}, port #{info.port})")
        0

      :stopped ->
        File.mkdir_p!(cms_home())
        spawn_detached(cms_bin)

        case wait_for_health(@start_timeout_s) do
          :ok ->
            case status() do
              {:running, info} ->
                IO.puts("cms v#{info.version} started  ·  pid #{info.pid || "?"}  ·  port #{info.port}")
                IO.puts("logs: #{info.log}")
                0

              :stopped ->
                IO.puts(:stderr, "cms: health check passed but status probe failed")
                1
            end

          {:error, reason} ->
            IO.puts(:stderr, "cms: failed to start (#{reason}). Last 20 log lines:")
            IO.puts(:stderr, tail_log(20))
            1
        end
    end
  end

  defp spawn_detached(cms_bin) do
    # nohup + stdin redirect + disown so the child survives our exit.
    # Stdout/stderr go to boot_log_file/0 (small, captures BEAM startup and
    # any IO.puts). Application :logger writes structured logfmt directly to
    # log_file/0 with size-based rotation — keeping them on separate FDs is
    # what lets rotation actually work.
    System.cmd(
      "sh",
      [
        "-c",
        "nohup #{shell_quote(cms_bin)} server >>#{shell_quote(boot_log_file())} 2>&1 </dev/null & disown"
      ]
    )
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  # --- stop -----------------------------------------------------------------

  @doc """
  Sends SIGTERM to the tracked PID, waits for exit, cleans up.
  Also sweeps orphan beam.smp processes that match our binary path.
  """
  def stop do
    case read_pid() do
      nil ->
        # No pid file — but maybe orphan beams linger from prior crashes.
        sweep_orphans()
        IO.puts("cms was not running")
        0

      pid ->
        System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)

        case wait_for_exit(pid, @stop_timeout_s) do
          :ok ->
            File.rm(pid_file())
            sweep_orphans()
            IO.puts("cms stopped")
            0

          {:error, :timeout} ->
            # Force-kill.
            System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
            File.rm(pid_file())
            sweep_orphans()
            IO.puts(:stderr, "cms: SIGTERM timed out after #{@stop_timeout_s}s, sent SIGKILL")
            0
        end
    end
  end

  defp sweep_orphans do
    {out, _} = System.cmd("pgrep", ["-f", "code_my_spec_cli"], stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.each(fn pid_str ->
      case Integer.parse(pid_str) do
        {pid, ""} -> System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
        _ -> :ok
      end
    end)
  end

  # --- logs -----------------------------------------------------------------

  def logs(follow?) do
    path = log_file()

    if not File.exists?(path) do
      IO.puts(:stderr, "cms: no log at #{path}")
      1
    else
      if follow? do
        # exec tail -f so Ctrl-C is handled naturally
        Port.open({:spawn_executable, find_tail()}, [
          :binary,
          :exit_status,
          args: ["-f", path]
        ])
        |> stream_port()
      else
        IO.puts(File.read!(path))
        0
      end
    end
  end

  defp find_tail, do: System.find_executable("tail") || "/usr/bin/tail"

  defp stream_port(port) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        stream_port(port)

      {^port, {:exit_status, code}} ->
        code
    end
  end

  def tail_log(n) do
    path = log_file()

    if File.exists?(path) do
      {out, _} = System.cmd("tail", ["-n", to_string(n), path])
      out
    else
      "(no log at #{path})"
    end
  end

  # --- internals ------------------------------------------------------------

  def write_pid_file do
    File.mkdir_p!(cms_home())
    File.write!(pid_file(), System.pid())
  end

  def remove_pid_file, do: File.rm(pid_file())

  defp read_pid do
    case File.read(pid_file()) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {pid, _} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp version do
    Application.spec(:code_my_spec, :vsn) |> to_string()
  end

  defp health_ok? do
    case System.cmd("curl", ["-sf", "--max-time", "2", @health_url], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_for_health(0), do: {:error, :timeout}

  defp wait_for_health(seconds_left) do
    if health_ok?() do
      :ok
    else
      Process.sleep(500)
      wait_for_health(seconds_left - 1)
    end
  end

  defp wait_for_exit(_pid, 0), do: {:error, :timeout}

  defp wait_for_exit(pid, seconds_left) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(500)
        wait_for_exit(pid, seconds_left - 1)

      _ ->
        :ok
    end
  end
end
