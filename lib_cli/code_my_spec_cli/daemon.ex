defmodule CodeMySpecCli.Daemon do
  @moduledoc """
  Daemon lifecycle for the cms CLI binary: status / start / stop / logs.

  The binary is normally run as a background server. These helpers make
  that explicit so users can ask "is it up?" without greping lsof, and
  the SessionStart hook can call `cms start` as a one-liner instead of
  managing nohup/disown/wait loops itself.

  OS abstraction lives at the bottom of this module — `host_os/0` returns
  `:unix | :windows` and the small wrappers below it (`spawn_detached`,
  `kill_pid`, `pid_alive?`, `sweep_orphans`, `follow_log`) branch on it.
  Health checks go through `:httpc` instead of shelling out to curl so
  there's nothing platform-specific in that path at all.
  """

  @port 4003
  @health_url "http://localhost:#{@port}/health"
  @start_timeout_s 60
  @stop_timeout_s 20

  # Data dir for db/logs/pid/binary. Honors CMS_HOME so the Windows Shawl
  # service can be launched with an explicit `--env CMS_HOME=<user>\.codemyspec`
  # (service profile loading isn't guaranteed, so we don't rely on `~`).
  # Defaults to ~/.codemyspec — the service runs as the logged-in user, so
  # this is the same dir whether resolved by the service or a user shell.
  def cms_home do
    case System.get_env("CMS_HOME") do
      nil -> Path.expand("~/.codemyspec")
      "" -> Path.expand("~/.codemyspec")
      dir -> dir
    end
  end
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
                IO.puts(
                  "cms v#{info.version} started  ·  pid #{info.pid || "?"}  ·  port #{info.port}"
                )

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

  # --- stop -----------------------------------------------------------------

  @doc """
  Sends the platform's "polite" terminate signal to the tracked PID
  (SIGTERM on unix, taskkill on Windows), waits for exit, escalates to
  force-kill on timeout, sweeps orphans.
  """
  def stop do
    case read_pid() do
      nil ->
        sweep_orphans()
        IO.puts("cms was not running")
        0

      pid ->
        kill_pid(pid, :graceful)

        case wait_for_exit(pid, @stop_timeout_s) do
          :ok ->
            File.rm(pid_file())
            sweep_orphans()
            IO.puts("cms stopped")
            0

          {:error, :timeout} ->
            kill_pid(pid, :force)
            File.rm(pid_file())
            sweep_orphans()

            IO.puts(
              :stderr,
              "cms: graceful stop timed out after #{@stop_timeout_s}s, force-killed"
            )

            0
        end
    end
  end

  # --- logs -----------------------------------------------------------------

  def logs(follow?) do
    path = log_file()

    if not File.exists?(path) do
      IO.puts(:stderr, "cms: no log at #{path}")
      1
    else
      if follow? do
        follow_log(path)
      else
        IO.puts(File.read!(path))
        0
      end
    end
  end

  # Read the tail of the log file purely in Elixir — no shell tail call.
  # Only used for error reporting, so the inefficiency of reading the whole
  # file doesn't matter.
  def tail_log(n) do
    path = log_file()

    if File.exists?(path) do
      path
      |> File.stream!(:line)
      |> Enum.to_list()
      |> Enum.take(-n)
      |> Enum.join()
    else
      "(no log at #{path})"
    end
  end

  # --- pid file -------------------------------------------------------------

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

  # --- health probe ---------------------------------------------------------

  defp health_ok? do
    # :inets is in extra_applications so :httpc is ready, but ensure_all_started
    # is cheap and idempotent — keeps this function self-contained for tests.
    {:ok, _} = Application.ensure_all_started(:inets)

    request = {String.to_charlist(@health_url), []}
    http_opts = [timeout: 2_000, connect_timeout: 1_000]
    opts = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, opts) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> true
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
    if pid_alive?(pid) do
      Process.sleep(500)
      wait_for_exit(pid, seconds_left - 1)
    else
      :ok
    end
  end

  # ==========================================================================
  # OS abstraction
  # ==========================================================================

  defp host_os do
    case :os.type() do
      {:win32, _} -> :windows
      _ -> :unix
    end
  end

  # --- spawn detached -------------------------------------------------------

  defp spawn_detached(cms_bin) do
    case host_os() do
      :unix -> spawn_detached_unix(cms_bin)
      :windows -> spawn_detached_windows(cms_bin)
    end
  end

  # nohup + stdin redirect + disown so the child survives our exit.
  # Stdout/stderr go to boot_log_file/0 (small, captures BEAM startup and
  # any IO.puts). Application :logger writes structured logfmt directly to
  # log_file/0 with size-based rotation — keeping them on separate FDs is
  # what lets rotation actually work.
  defp spawn_detached_unix(cms_bin) do
    System.cmd(
      "sh",
      [
        "-c",
        "nohup #{shell_quote(cms_bin)} server >>#{shell_quote(boot_log_file())} 2>&1 </dev/null & disown"
      ]
    )
  end

  # `cmd /c start "" /B …` is the Windows analogue of nohup+disown: `start`
  # returns immediately and the spawned process keeps running after cmd
  # exits. The empty `""` is the window title `start` insists on consuming
  # before the program path. Redirection works because `/B` runs the child
  # in the same console and inherits the redirected handles.
  defp spawn_detached_windows(cms_bin) do
    line =
      ~s(start "" /B ) <>
        win_quote(cms_bin) <>
        " server >> " <>
        win_quote(boot_log_file()) <>
        " 2>&1"

    System.cmd("cmd", ["/c", line])
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  # cmd.exe quoting: wrap in double quotes, escape embedded quotes by
  # doubling. Paths under ~/.codemyspec never contain quotes in practice,
  # but the escape keeps us safe if the user's home does.
  defp win_quote(s), do: ~s(") <> String.replace(s, ~s("), ~s("")) <> ~s(")

  # --- kill -----------------------------------------------------------------

  defp kill_pid(pid, mode) do
    case host_os() do
      :unix -> kill_pid_unix(pid, mode)
      :windows -> kill_pid_windows(pid, mode)
    end
  end

  defp kill_pid_unix(pid, :graceful),
    do: System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)

  defp kill_pid_unix(pid, :force),
    do: System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)

  # `taskkill /PID` is the closest analogue to SIGTERM for a console app on
  # Windows. With `/F` it's the equivalent of SIGKILL.
  defp kill_pid_windows(pid, :graceful),
    do: System.cmd("taskkill", ["/PID", to_string(pid)], stderr_to_stdout: true)

  defp kill_pid_windows(pid, :force),
    do: System.cmd("taskkill", ["/F", "/PID", to_string(pid)], stderr_to_stdout: true)

  # --- liveness -------------------------------------------------------------

  defp pid_alive?(pid) do
    case host_os() do
      :unix -> pid_alive_unix?(pid)
      :windows -> pid_alive_windows?(pid)
    end
  end

  defp pid_alive_unix?(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # tasklist exits 0 whether or not the PID is present; you have to look at
  # the output. The "INFO:" prefix is the "no match" sentinel; otherwise the
  # PID appears in a column.
  defp pid_alive_windows?(pid) do
    case System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH"], stderr_to_stdout: true) do
      {out, 0} ->
        out = String.trim(out)

        out != "" and not String.starts_with?(out, "INFO:") and
          String.contains?(out, to_string(pid))

      _ ->
        false
    end
  end

  # --- orphan sweep ---------------------------------------------------------

  # Defensive cleanup against orphans left by prior crashes — matches by
  # binary basename in the command line. Best-effort; failures are silent.
  defp sweep_orphans do
    case host_os() do
      :unix -> sweep_orphans_unix()
      :windows -> sweep_orphans_windows()
    end
  end

  defp sweep_orphans_unix do
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

  # PowerShell command-line match. `wmic` is being phased out across recent
  # Windows builds; the Get-CimInstance equivalent is the supported path.
  defp sweep_orphans_windows do
    ps =
      "Get-CimInstance Win32_Process | " <>
        "Where-Object { $_.CommandLine -like '*code_my_spec_cli*' } | " <>
        "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

    System.cmd("powershell", ["-NoProfile", "-Command", ps], stderr_to_stdout: true)
  end

  # --- log follow -----------------------------------------------------------

  defp follow_log(path) do
    case host_os() do
      :unix -> follow_log_unix(path)
      :windows -> follow_log_windows(path)
    end
  end

  defp follow_log_unix(path) do
    Port.open({:spawn_executable, find_tail()}, [
      :binary,
      :exit_status,
      args: ["-f", path]
    ])
    |> stream_port()
  end

  defp follow_log_windows(path) do
    ps_exe = System.find_executable("powershell") || "powershell.exe"

    Port.open({:spawn_executable, ps_exe}, [
      :binary,
      :exit_status,
      args: [
        "-NoProfile",
        "-Command",
        "Get-Content -Wait -Tail 0 -Path " <> win_quote(path)
      ]
    ])
    |> stream_port()
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
end
