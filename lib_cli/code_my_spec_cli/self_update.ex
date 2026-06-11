defmodule CodeMySpecCli.SelfUpdate do
  @moduledoc """
  Self-update the cms binary from GitHub releases.

  Two entry points, both comparing the running version against the latest
  published release and swapping the on-disk binary (rename-aside) when newer:

    * `run/1` — the `cms self-update` CLI command (unix / manual). Stops the
      detached server, swaps, and restarts it via `Daemon`.
    * `update_in_place/0` — for the server supervising itself. Swaps the
      binary and returns `:updated`; the caller exits nonzero so its
      supervisor relaunches the new binary. On Windows that supervisor is the
      Shawl-wrapped service (default restart-on-nonzero), so a single exit
      picks up the new binary — no service control, no detached respawn.

  Progress is logged to `~/.codemyspec/auto-update.log`.

  First-install (no binary on disk) is *not* handled here — the platform
  install script handles that. There's an obvious chicken-and-egg with `cms`
  self-installing.
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

  @doc """
  In-process update path for a server that is restarted by its supervisor on
  nonzero exit (the Windows Shawl service). Checks the latest release against
  the *running* version; if newer, downloads and swaps the on-disk binary and
  returns `:updated` so the caller can `System.halt/1` nonzero — the
  supervisor then relaunches the new binary. Returns `:current` or `:error`
  otherwise, and never restarts the server itself.
  """
  def update_in_place do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    cms_home = Daemon.cms_home()
    File.mkdir_p!(bin_dir(cms_home))
    lock = Path.join(cms_home, "auto-update.lock")
    log = log_fn(Path.join(cms_home, "auto-update.log"))

    case acquire_lock(lock) do
      :ok ->
        try do
          do_update_in_place(cms_home, log)
        after
          File.rm(lock)
        end

      :held ->
        :current
    end
  end

  defp do_update_in_place(cms_home, log) do
    bin_path = Path.join(bin_dir(cms_home), binary_filename())
    local = running_version()
    log.("Running version: #{local}")

    with {:ok, remote} <- remote_version(log),
         true <- version_gt?(remote, local),
         true <- File.exists?(bin_path),
         {:ok, tmp} <- download_version(remote, log) do
      swap_files(bin_path, tmp)
      log.("Swapped to v#{remote}; exiting for supervisor restart")
      :updated
    else
      false ->
        log.("No update for running version #{local}")
        :current

      :error ->
        :error
    end
  end

  defp running_version do
    Application.spec(:code_my_spec, :vsn) |> to_string()
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
    case download_version(remote, log) do
      {:ok, tmp} ->
        swap_binary(bin_path, tmp)
        log.("Updated to v#{remote}")
        0

      :error ->
        0
    end
  end

  # Download the release binary for `remote` to a tmp path. {:ok, tmp} | :error.
  defp download_version(remote, log) do
    tag = "v#{remote}"
    asset = asset_name()

    with {:ok, release} <- http_json("#{@releases_api}/tags/#{tag}"),
         {:ok, url} <- find_asset_url(release, asset) do
      tmp = Path.join(System.tmp_dir!(), "cms_self_update_#{System.unique_integer([:positive])}")

      case http_download(url, tmp) do
        :ok ->
          {:ok, tmp}

        {:error, reason} ->
          File.rm(tmp)
          log.("Download failed: #{inspect(reason)}")
          :error
      end
    else
      _ ->
        log.("No asset #{asset} in #{tag}")
        :error
    end
  end

  # CLI / manual path (unix): stop the detached server, swap, restart it.
  defp swap_binary(bin_path, tmp) do
    Daemon.stop()
    swap_files(bin_path, tmp)
    Daemon.start(bin_path)
  end

  # Move the new binary into place. On Windows a running .exe can be renamed
  # but not overwritten, so rename-aside first, then rename-into-place — works
  # the same on unix. Crucially this does NOT restart anything: under the
  # Windows Shawl service the caller halts with a nonzero code and Shawl
  # relaunches from this path, now holding the new binary.
  defp swap_files(bin_path, tmp) do
    aside = bin_path <> ".old"
    File.rm(aside)
    if File.exists?(bin_path), do: File.rename!(bin_path, aside)
    File.rename!(tmp, bin_path)

    case :os.type() do
      {:win32, _} -> :ok
      _ -> File.chmod!(bin_path, 0o755)
    end

    File.rm(aside)
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
