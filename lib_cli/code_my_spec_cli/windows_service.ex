defmodule CodeMySpecCli.WindowsService do
  @moduledoc """
  Manage the `cms` binary as a Windows service, supervised by Shawl.

  Shawl (https://github.com/mtkennerly/shawl) is a tiny Rust wrapper that
  runs an arbitrary console program as a Windows service: it forwards the
  service-control stop into a ctrl-C, restarts the program on exit, and
  captures its stdout/stderr to a log. We register `cms server` under it so
  the local Phoenix/MCP server runs as a real auto-starting service instead
  of a hook-spawned detached process.

  This module is the whole Windows lifecycle — install / uninstall / start /
  stop / restart / status — and it is intentionally **decoupled from the
  Claude Code plugin**. The plugin only talks to the server on its port; it
  never installs, starts, or updates the binary. The standalone installer
  (`installers/windows/install.ps1`) drops `cms.exe` and calls
  `cms service install`; `cms self-update` keeps it current in place.

  ## Why LocalSystem + ProgramData

  `sc create` (which Shawl drives) registers the service as LocalSystem by
  default — no password, starts with the machine, no logged-in user
  required. Under LocalSystem `~` resolves to the system profile, so the
  service is launched with `--env CMS_HOME=#{inspect("C:\\\\ProgramData\\\\CodeMySpec")}`
  and the binary itself defaults `cms_home/0` to the same path on Windows.
  Service and any user-run `cms` command therefore agree on one data dir.

  Every public function returns a process exit code (0 = success) so the CLI
  dispatcher can `System.halt/1` on the result. Everything is a no-op with a
  clear message off Windows.
  """

  alias CodeMySpecCli.Daemon

  @service_name "CodeMySpec"
  @description "CodeMySpec local server (Phoenix + MCP) on port 4003."
  @shawl_version "v1.9.0"
  @shawl_zip "shawl-#{@shawl_version}-win64.zip"
  @shawl_url "https://github.com/mtkennerly/shawl/releases/download/#{@shawl_version}/#{@shawl_zip}"

  # Time Shawl waits between the ctrl-C and force-killing the BEAM. The app's
  # own graceful shutdown is fast; 20s is generous headroom.
  @stop_timeout_ms 20_000
  @download_timeout 120_000
  @start_settle_s 60

  def service_name, do: @service_name

  # --- public lifecycle -----------------------------------------------------

  @doc """
  Register the Shawl-wrapped service, set it to auto-start, and start it.
  Idempotent: reconfigures an existing service rather than failing.
  """
  def install do
    with :ok <- require_windows(),
         :ok <- ensure_admin(),
         {:ok, shawl} <- ensure_shawl(),
         {:ok, cms} <- locate_binary() do
      do_install(shawl, cms)
    else
      {:error, code} when is_integer(code) -> code
      {:error, msg} -> fail(msg)
    end
  end

  @doc "Stop and delete the service. Leaves the binary and data dir in place."
  def uninstall do
    with :ok <- require_windows(),
         :ok <- ensure_admin() do
      if installed?() do
        _ = sc(["stop", @service_name])
        wait_stopped(@start_settle_s)

        case sc(["delete", @service_name]) do
          {_out, 0} ->
            ok("Service #{@service_name} deleted.")

          {out, code} ->
            fail("sc delete failed (#{code}): #{String.trim(out)}")
        end
      else
        ok("Service #{@service_name} is not installed.")
      end
    else
      {:error, code} when is_integer(code) -> code
      {:error, msg} -> fail(msg)
    end
  end

  def start do
    with :ok <- require_windows(),
         :ok <- require_installed() do
      case sc(["start", @service_name]) do
        {_out, 0} -> settle_started()
        # 1056 = service already running.
        {_out, 1056} -> ok("Service #{@service_name} already running.")
        {out, code} -> fail("sc start failed (#{code}): #{String.trim(out)}")
      end
    else
      {:error, code} when is_integer(code) -> code
      {:error, msg} -> fail(msg)
    end
  end

  def stop do
    with :ok <- require_windows(),
         :ok <- require_installed() do
      case sc(["stop", @service_name]) do
        {_out, 0} ->
          wait_stopped(@start_settle_s)
          ok("Service #{@service_name} stopped.")

        # 1062 = service not started.
        {_out, 1062} ->
          ok("Service #{@service_name} was not running.")

        {out, code} ->
          fail("sc stop failed (#{code}): #{String.trim(out)}")
      end
    else
      {:error, code} when is_integer(code) -> code
      {:error, msg} -> fail(msg)
    end
  end

  def restart do
    case stop() do
      0 -> start()
      code -> code
    end
  end

  def print_status do
    case require_windows() do
      :ok ->
        if installed?() do
          {out, _} = sc(["query", @service_name])
          IO.puts(String.trim(out))
          0
        else
          IO.puts(:stderr, "cms service: #{@service_name} is not installed")
          1
        end

      {:error, msg} ->
        fail(msg)
    end
  end

  @doc "True if the Windows service is registered. False off Windows."
  def installed? do
    case :os.type() do
      {:win32, _} ->
        match?({_out, 0}, sc(["query", @service_name]))

      _ ->
        false
    end
  end

  # --- install internals ----------------------------------------------------

  defp do_install(shawl, cms) do
    home = Daemon.cms_home()
    log_dir = Path.join(home, "shawl")
    File.mkdir_p!(home)
    File.mkdir_p!(log_dir)

    # If the service already exists, delete-and-recreate so flag changes
    # (binary path, env, restart policy) actually take effect.
    if installed?() do
      _ = sc(["stop", @service_name])
      wait_stopped(@start_settle_s)
      _ = sc(["delete", @service_name])
      wait_absent(10)
    end

    add_args =
      [
        "add",
        "--name",
        @service_name,
        "--restart",
        "--stop-timeout",
        Integer.to_string(@stop_timeout_ms),
        "--cwd",
        home,
        "--log-dir",
        log_dir,
        "--env",
        "CMS_HOME=#{home}",
        "--",
        cms,
        "server"
      ]

    case cmd(shawl, add_args) do
      {_out, 0} ->
        # Shawl/sc default to demand-start; promote to auto so it boots
        # with the machine. Note the required space after `start=`.
        _ = sc(["config", @service_name, "start=", "auto"])
        _ = sc(["description", @service_name, @description])
        persist_cms_home_env(home)

        case sc(["start", @service_name]) do
          {_out, 0} -> settle_started()
          {out, code} -> fail("Service registered but failed to start (#{code}): #{String.trim(out)}")
        end

      {out, code} ->
        fail("shawl add failed (#{code}): #{String.trim(out)}")
    end
  end

  # Make `cms` commands a user later runs in their own session resolve the
  # same data dir as the service. setx writes the machine-level env var
  # (requires the elevation we already checked for).
  defp persist_cms_home_env(home) do
    _ = cmd("setx", ["/M", "CMS_HOME", home])
    :ok
  end

  # --- shawl provisioning ---------------------------------------------------

  # Returns {:ok, path_to_shawl_exe}. Downloads + extracts the pinned Shawl
  # release into the bin dir on first install; reuses it thereafter.
  defp ensure_shawl do
    bin = bin_dir()
    File.mkdir_p!(bin)
    shawl = Path.join(bin, "shawl.exe")

    if File.exists?(shawl) do
      {:ok, shawl}
    else
      download_shawl(bin, shawl)
    end
  end

  defp download_shawl(bin, shawl) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    zip = Path.join(System.tmp_dir!(), @shawl_zip)
    IO.puts("Downloading Shawl #{@shawl_version}…")

    with :ok <- http_download(@shawl_url, zip),
         {:ok, _files} <- unzip(zip, bin) do
      File.rm(zip)

      if File.exists?(shawl) do
        {:ok, shawl}
      else
        {:error, "Shawl archive did not contain shawl.exe"}
      end
    else
      {:error, reason} ->
        File.rm(zip)
        {:error, "could not provision Shawl: #{inspect(reason)}"}
    end
  end

  defp unzip(zip, dest) do
    case :zip.unzip(String.to_charlist(zip), cwd: String.to_charlist(dest)) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- binary location ------------------------------------------------------

  # The canonical install path. The standalone installer places cms.exe here
  # before calling `service install`; if we're somehow running from a
  # different copy, copy ourselves into place so the service path is stable.
  defp locate_binary do
    canonical = Path.join(bin_dir(), "cms.exe")

    cond do
      File.exists?(canonical) ->
        {:ok, canonical}

      true ->
        case running_binary() do
          nil ->
            {:error, "cms.exe not found at #{canonical} — run the installer first"}

          self_path ->
            File.mkdir_p!(bin_dir())
            File.cp!(self_path, canonical)
            {:ok, canonical}
        end
    end
  end

  defp running_binary do
    case :init.get_plain_arguments() do
      [first | _] -> to_string(first)
      _ -> System.get_env("_")
    end
  end

  defp bin_dir, do: Path.join(Daemon.cms_home(), "bin")

  # --- guards ---------------------------------------------------------------

  defp require_windows do
    case :os.type() do
      {:win32, _} -> :ok
      _ -> {:error, "cms service is Windows-only (macOS/Linux use a different supervisor)"}
    end
  end

  defp require_installed do
    if installed?() do
      :ok
    else
      {:error, "service #{@service_name} is not installed — run `cms service install`"}
    end
  end

  # Best-effort elevation check. `net session` only succeeds when elevated.
  # We warn rather than hard-block so an already-elevated context that
  # somehow fails the probe can still proceed; sc surfaces a clear access
  # error (exit 5) if we really lack rights.
  defp ensure_admin do
    case cmd("net", ["session"]) do
      {_out, 0} ->
        :ok

      _ ->
        IO.puts(:stderr, "cms service: not running elevated — re-run from an Administrator shell.")
        {:error, "administrator privileges required"}
    end
  end

  # --- start/stop settling --------------------------------------------------

  defp settle_started do
    case wait_health(@start_settle_s) do
      :ok ->
        ok("Service #{@service_name} started and healthy on :4003.")

      :timeout ->
        IO.puts(:stderr, "cms service: started but /health did not respond within #{@start_settle_s}s")
        IO.puts(:stderr, "check #{Path.join([Daemon.cms_home(), "shawl"])} for Shawl logs")
        1
    end
  end

  defp wait_health(0), do: :timeout

  defp wait_health(n) do
    if Daemon.health_ok?() do
      :ok
    else
      Process.sleep(1000)
      wait_health(n - 1)
    end
  end

  defp wait_stopped(0), do: :ok

  defp wait_stopped(n) do
    case sc(["query", @service_name]) do
      {out, 0} ->
        if String.contains?(out, "STOPPED") do
          :ok
        else
          Process.sleep(1000)
          wait_stopped(n - 1)
        end

      _ ->
        :ok
    end
  end

  defp wait_absent(0), do: :ok

  defp wait_absent(n) do
    if installed?() do
      Process.sleep(1000)
      wait_absent(n - 1)
    else
      :ok
    end
  end

  # --- shelling out ---------------------------------------------------------

  defp sc(args), do: cmd("sc", args)

  defp cmd(exe, args) do
    System.cmd(exe, args, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {Exception.message(e), 127}
  end

  defp http_download(url, dest) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"codemyspec-service"}]}
    http_opts = [timeout: @download_timeout, connect_timeout: 5_000, autoredirect: true]

    case :httpc.request(:get, request, http_opts, stream: String.to_charlist(dest)) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- result helpers -------------------------------------------------------

  defp ok(msg) do
    IO.puts(msg)
    0
  end

  defp fail(msg) do
    IO.puts(:stderr, "cms service: #{msg}")
    1
  end
end
