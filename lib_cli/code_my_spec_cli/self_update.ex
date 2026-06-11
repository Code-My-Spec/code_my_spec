defmodule CodeMySpecCli.SelfUpdate do
  @moduledoc """
  Self-update the cms binary from GitHub releases.

  Compares the running binary's version against the latest published release.
  If a newer version exists, stops the server, downloads the binary, swaps it
  into place, and restarts the server.

  Replaces the bash `auto-update` script. The SessionStart hook fires
  `cms self-update` in the background and we log progress to
  `~/.codemyspec/auto-update.log` for backwards-compatible debugging.

  First-install (no binary on disk) is *not* handled here — the SessionStart
  hook or the platform install script (`install.sh` / `install.ps1`) handles
  that. There's an obvious chicken-and-egg with `cms` self-installing.
  """

  alias CodeMySpecCli.Daemon

  @repo "Code-My-Spec/plugins"
  @releases_api "https://api.github.com/repos/#{@repo}/releases"
  @api_timeout 5_000
  @download_timeout 120_000
  @lock_stale_seconds 300

  @doc """
  Entry point for `cms self-update`. Always returns 0 — failures are logged
  and the next session retries. The hook backgrounds this; treating it as
  fatal would just surface noise.
  """
  def run(_args \\ []) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    cms_home = Daemon.cms_home()
    File.mkdir_p!(bin_dir(cms_home))

    lock = Path.join(cms_home, "auto-update.lock")
    log = log_fn(Path.join(cms_home, "auto-update.log"))

    case acquire_lock(lock) do
      :ok ->
        try do
          do_update(cms_home, log)
        after
          File.rm(lock)
        end

      :held ->
        0
    end
  end

  defp do_update(cms_home, log) do
    bin_path = Path.join(bin_dir(cms_home), binary_filename())

    if File.exists?(bin_path) do
      local = local_version(bin_path)
      log.("Local version: #{local}")

      case remote_version(log) do
        {:ok, ^local} ->
          log.("Already up to date")
          0

        {:ok, remote} ->
          if version_gt?(remote, local) do
            log.("Update available: #{local} -> #{remote}")
            install_version(remote, bin_path, log)
          else
            log.("Local (#{local}) is newer than remote (#{remote})")
            0
          end

        :error ->
          0
      end
    else
      log.("Binary missing at #{bin_path} — run the platform install script first")
      0
    end
  end

  # --- platform -------------------------------------------------------------

  defp binary_filename do
    case :os.type() do
      {:win32, _} -> "cms.exe"
      _ -> "cms"
    end
  end

  defp asset_name do
    {os, arch} = platform()
    suffix = if os == "windows", do: ".exe", else: ""
    "cms-#{os}-#{arch}#{suffix}"
  end

  defp platform do
    case :os.type() do
      {:win32, _} -> {"windows", "x64"}
      {:unix, :darwin} -> {"darwin", cpu_arch()}
      {:unix, :linux} -> {"linux", cpu_arch()}
    end
  end

  defp cpu_arch do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.contains?(arch, "aarch64") -> "arm64"
      String.contains?(arch, "arm64") -> "arm64"
      true -> "x64"
    end
  end

  defp bin_dir(cms_home), do: Path.join(cms_home, "bin")

  # --- version --------------------------------------------------------------

  defp local_version(bin_path) do
    case System.cmd(bin_path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split(~r/\s+/)
        |> List.last()
        |> Kernel.||("0.0.0")

      _ ->
        "0.0.0"
    end
  end

  defp remote_version(log) do
    case http_json("#{@releases_api}/latest") do
      {:ok, %{"tag_name" => tag}} ->
        {:ok, String.trim_leading(tag, "v")}

      {:error, reason} ->
        log.("Could not fetch remote version (#{inspect(reason)})")
        :error
    end
  end

  defp version_gt?(a, b), do: parse_version(a) > parse_version(b)

  defp parse_version(v) do
    v
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end

  # --- install --------------------------------------------------------------

  defp install_version(remote, bin_path, log) do
    tag = "v#{remote}"
    asset = asset_name()

    with {:ok, release} <- http_json("#{@releases_api}/tags/#{tag}"),
         {:ok, url} <- find_asset_url(release, asset) do
      tmp =
        Path.join(System.tmp_dir!(), "cms_self_update_#{System.unique_integer([:positive])}")

      case http_download(url, tmp) do
        :ok ->
          swap_binary(bin_path, tmp, log)
          log.("Updated to #{tag}")
          0

        {:error, reason} ->
          File.rm(tmp)
          log.("Download failed: #{inspect(reason)}")
          0
      end
    else
      _ ->
        log.("No asset #{asset} in #{tag}")
        0
    end
  end

  # Stop server, swap binary, start. On Windows you can rename a running
  # .exe but not overwrite it — rename-aside first, then rename-into-place.
  # Same dance works fine on Unix.
  #
  # When the binary runs as a Windows Shawl service we drive the swap through
  # the service control manager: `sc stop` (Shawl tears down without
  # restarting, since the service is stopping), swap, `sc start` (Shawl
  # relaunches from the same path — now the new binary). Going through
  # Daemon.stop/start here would taskkill the process out from under Shawl,
  # which would just restart the OLD binary and spawn a competing detached
  # copy on the same port.
  defp swap_binary(bin_path, tmp, log) do
    service? = service_managed?()
    stop_server(service?, log)

    aside = bin_path <> ".old"
    File.rm(aside)
    if File.exists?(bin_path), do: File.rename!(bin_path, aside)
    File.rename!(tmp, bin_path)

    case :os.type() do
      {:win32, _} -> :ok
      _ -> File.chmod!(bin_path, 0o755)
    end

    File.rm(aside)
    start_server(service?, bin_path, log)
  end

  defp service_managed? do
    match?({:win32, _}, :os.type()) and CodeMySpecCli.WindowsService.installed?()
  end

  defp stop_server(true, log) do
    log.("Stopping Windows service before swap")
    System.cmd("sc", ["stop", CodeMySpecCli.WindowsService.service_name()], stderr_to_stdout: true)
    wait_service_stopped(60)
  end

  defp stop_server(false, _log), do: Daemon.stop()

  defp start_server(true, _bin_path, log) do
    log.("Starting Windows service after swap")
    System.cmd("sc", ["start", CodeMySpecCli.WindowsService.service_name()], stderr_to_stdout: true)
  end

  defp start_server(false, bin_path, _log), do: Daemon.start(bin_path)

  defp wait_service_stopped(0), do: :ok

  defp wait_service_stopped(n) do
    case System.cmd("sc", ["query", CodeMySpecCli.WindowsService.service_name()],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        if String.contains?(out, "STOPPED") do
          :ok
        else
          Process.sleep(1000)
          wait_service_stopped(n - 1)
        end

      _ ->
        :ok
    end
  end

  defp find_asset_url(%{"assets" => assets}, name) when is_list(assets) do
    Enum.find_value(assets, :error, fn
      %{"name" => ^name, "browser_download_url" => url} -> {:ok, url}
      _ -> nil
    end)
  end

  defp find_asset_url(_, _), do: :error

  # --- locking --------------------------------------------------------------

  defp acquire_lock(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age = System.system_time(:second) - mtime

        if age < @lock_stale_seconds do
          :held
        else
          write_lock(lock_path)
        end

      {:error, :enoent} ->
        write_lock(lock_path)
    end
  end

  defp write_lock(lock_path) do
    File.write!(lock_path, to_string(System.pid()))
    :ok
  end

  # --- http -----------------------------------------------------------------

  defp http_json(url) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"codemyspec-self-update"}]}
    http_opts = [timeout: @api_timeout, connect_timeout: 3_000, autoredirect: true]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_download(url, dest) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"codemyspec-self-update"}]}
    http_opts = [timeout: @download_timeout, connect_timeout: 5_000, autoredirect: true]

    case :httpc.request(:get, request, http_opts, stream: String.to_charlist(dest)) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- log ------------------------------------------------------------------

  defp log_fn(log_path) do
    fn msg ->
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      File.write!(log_path, "[#{ts}] #{msg}\n", [:append])
      :ok
    end
  end
end
