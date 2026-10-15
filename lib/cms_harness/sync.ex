defmodule CmsHarness.Sync do
  @moduledoc """
  Scan a working copy and hand the manifest to the channel.

  Runs under the copy's own `Task.Supervisor`, never in the channel process: a
  full scan reads and hashes every file and would stall the socket.

  The scan is the shared `CodeMySpec.Files.Scanner`, so harness and server
  cannot disagree about what a file is. Also reports what only this machine
  can read: app name, health route, HEAD, preview health and machine load.
  See knowledge/harness, "Sync".
  """

  require Logger

  alias CmsHarness.Channel
  alias CmsHarness.HarnessConfig
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Generators.DeployBoilerplate

  @doc """
  Kick off a scan for a project. Returns immediately.
  """
  @spec start(map(), ReadModel.t()) :: :ok
  def start(project, %ReadModel{} = read_model) do
    case Task.Supervisor.start_child(task_supervisor(project.root), fn ->
           run(project, read_model)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        # Loudly: a sync that silently does not happen looks like nothing to do.
        Logger.error(
          "[CmsHarness] could not start a scan of #{project.root}: #{inspect(reason)}. " <>
            "The server's view of this project is now stale and nothing will say so."
        )

        :ok
    end
  end

  @doc """
  Walk the working copy and deliver the result. Public so it can be driven
  directly in a test without a supervisor.
  """
  @spec run(map(), ReadModel.t()) :: :ok
  def run(project, %ReadModel{} = read_model) do
    started = System.monotonic_time(:millisecond)
    env = Environment.new(:local, project.root)

    report_app_name(env, project.root)
    report_head_commit(env, project.root)
    report_preview_health(env, project.root)

    case Scanner.observe(env, read_model) do
      {:error, reason} ->
        Logger.error(
          "[CmsHarness] could not scan #{project.root}: #{inspect(reason)}. Sending " <>
            "nothing — a manifest is the whole truth about a working copy, so an empty " <>
            "one tells the server every file here was deleted."
        )

        :ok

      # Handed on, not refused here; `ChannelClient` decides whether an empty
      # manifest is sent, and says so. This line says only what was found.
      {:ok, []} ->
        Logger.error(
          "[CmsHarness] scanned #{project.root} and found no trackable files. For an " <>
            "established project that is almost always a wrong or unreadable root — " <>
            "check the root and the sync roots. Whether an empty manifest is sent is " <>
            "the channel's call, and it says so on the next line."
        )

        Channel.deliver_observations(project.root, [])

      {:ok, observations} ->
        Logger.info(
          "[CmsHarness] scanned #{length(observations)} files in #{project.root} " <>
            "in #{System.monotonic_time(:millisecond) - started}ms"
        )

        log_unclassified(env, project.root)

        Channel.deliver_observations(project.root, observations)
    end
  end

  # The server cannot read this checkout's `mix.exs`; this machine reports the
  # app name on every sync, which also corrects a wrong `module_name`.
  defp report_app_name(env, root) do
    case Environments.mix_exs_app_name(env) do
      # `module_name` stores the CamelCase form.
      name when is_binary(name) ->
        Channel.deliver_module_name(root, Macro.camelize(name))
        report_health_route(env, root, name)

      nil ->
        :ok
    end
  end

  @doc """
  Measure this checkout's preview and report it, independent of a scan: an app
  crashes and recovers while no file changes.
  """
  @spec measure_preview(String.t()) :: :ok
  def measure_preview(root) do
    :local |> Environment.new(root) |> report_preview_health(root)
  end

  @doc """
  Re-measure this checkout on the channel's timer, independent of a scan.
  Currently the preview's health only.
  """
  @spec measure_checkout(String.t()) :: :ok
  def measure_checkout(root) do
    env = Environment.new(:local, root)

    report_preview_health(env, root)
  end

  @doc """
  Re-measure what the machine this checkout runs on is carrying, independent
  of a scan and on its own clock, for the same reason `measure_checkout/1` is:
  a saturated box gets more or less saturated while nobody touches a file.

  Without it a saturated machine reads as several slow agents, and restarting
  them makes it worse.

  Plain `System.cmd`/`/proc`, not `Environments` (which reaches a checkout,
  not this box) and not `:os_mon` (not started). Fields a platform cannot
  answer are omitted.
  """
  @spec measure_machine_load(String.t()) :: :ok
  def measure_machine_load(root) do
    case machine_load() do
      load when map_size(load) > 0 -> Channel.deliver_machine_load(root, load)
      _ -> :ok
    end
  end

  defp machine_load do
    platform_load =
      case :os.type() do
        {:unix, :darwin} -> darwin_load()
        {:unix, _} -> linux_load()
        _ -> %{}
      end

    Map.merge(platform_load, cpu_count())
  end

  # What the BEAM was given (cgroup/taskset), not what the hardware has: the
  # number `Machinery.saturated?/2` compares `load_average` against.
  defp cpu_count do
    case :erlang.system_info(:logical_processors_available) do
      n when is_integer(n) and n > 0 -> %{"cpu_count" => n}
      _ -> %{}
    end
  end

  defp darwin_load do
    Map.merge(darwin_load_average(), darwin_memory_free_mb())
  end

  defp darwin_load_average do
    case System.cmd("sysctl", ["-n", "vm.loadavg"], stderr_to_stdout: true) do
      {out, 0} -> parse_darwin_loadavg(out)
      _ -> %{}
    end
  end

  # "{ 1.23 2.45 2.10 }\n": the one-minute average. `Float.parse/1`, since
  # `String.to_float/1` raises on "31".
  defp parse_darwin_loadavg(out) do
    with [_, average] <- Regex.run(~r/\{\s*([\d.]+)/, out),
         {load, _rest} <- Float.parse(average) do
      %{"load_average" => load}
    else
      _ -> %{}
    end
  end

  defp darwin_memory_free_mb do
    case System.cmd("vm_stat", [], stderr_to_stdout: true) do
      {out, 0} -> parse_darwin_vm_stat(out)
      _ -> %{}
    end
  end

  # Free plus speculative pages: both are reclaimable with no write-back.
  defp parse_darwin_vm_stat(out) do
    with [_, page_size] <- Regex.run(~r/page size of (\d+) bytes/, out),
         [_, free] <- Regex.run(~r/Pages free:\s*(\d+)/, out),
         [_, speculative] <- Regex.run(~r/Pages speculative:\s*(\d+)/, out) do
      bytes =
        (String.to_integer(free) + String.to_integer(speculative)) * String.to_integer(page_size)

      %{"memory_free_mb" => div(bytes, 1_048_576)}
    else
      _ -> %{}
    end
  end

  # `/proc` directly: no shell-out, and `File.read/1` never raises.
  defp linux_load do
    Map.merge(linux_load_average(), linux_memory_free_mb())
  end

  defp linux_load_average do
    case File.read("/proc/loadavg") do
      {:ok, contents} -> parse_linux_loadavg(contents)
      {:error, _} -> %{}
    end
  end

  # "0.08 0.03 0.01 1/512 12345\n": the one-minute average.
  defp parse_linux_loadavg(contents) do
    case String.split(contents, " ", trim: true) do
      [one | _] ->
        case Float.parse(one) do
          {average, _} -> %{"load_average" => average}
          :error -> %{}
        end

      _ ->
        %{}
    end
  end

  defp linux_memory_free_mb do
    case File.read("/proc/meminfo") do
      {:ok, contents} -> parse_linux_meminfo(contents)
      {:error, _} -> %{}
    end
  end

  # `MemAvailable`, not `MemFree`: the kernel's estimate including page cache.
  defp parse_linux_meminfo(contents) do
    case Regex.run(~r/^MemAvailable:\s*(\d+) kB/m, contents) do
      [_, kb] -> %{"memory_free_mb" => div(String.to_integer(kb), 1024)}
      _ -> %{}
    end
  end

  # Against `preview_url` (what QA opens), from this copy's `.cms_harness.json`.
  # Silent when none is recorded: an un-previewed copy has nothing to be up.
  defp report_preview_health(env, root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{preview_url: url}} when is_binary(url) and url != "" ->
        status = preview_status(env, url)
        Logger.info("[CmsHarness] #{url} is #{status}")
        Channel.deliver_preview_status(root, status)

      _ ->
        :ok
    end
  end

  # `curl` through the environment: tunnel, proxy or port alike.
  defp preview_status(env, url) do
    case Environments.cmd(
           env,
           "curl",
           ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", url],
           stderr_to_stdout: true
         ) do
      {code, 0} -> classify(String.trim(code))
      _ -> "down"
    end
  end

  # Edge codes for "the request never reached an application" (a Cloudflare
  # tunnel with no origin answers 530; a proxy, 502). Those are `down`;
  # `erroring` means the app itself answered and failed.
  @no_origin [502, 520, 521, 522, 523, 524, 525, 526, 527, 530]

  @doc """
  What an HTTP status from a preview address says about the application.

  Public because it is the whole of the judgement, and is tested directly.
  """
  @spec classify(String.t()) :: String.t()
  def classify("000"), do: "down"

  def classify(code) do
    case Integer.parse(code) do
      {status, _} when status in @no_origin -> "down"
      {status, _} when status >= 500 -> "erroring"
      {status, _} when status > 0 -> "serving"
      _ -> "down"
    end
  end

  # The checkout's real HEAD, which the server cannot read (`Steps.image_tag/2`
  # falls back to it). Reported on every sync and at each agent turn end, since
  # a commit changes no file a sync watches.
  @doc "Report `root`'s HEAD to the server."
  @spec report_head(String.t()) :: :ok
  def report_head(root), do: report_head_commit(Environment.new(:local, root), root)

  defp report_head_commit(env, root) do
    case Environments.cmd(env, "git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> Channel.deliver_head_commit(root, String.trim(sha))
      _ -> :ok
    end
  end

  # A content check of `router.ex` the server cannot read. The three strings
  # are fixed by `Project.changeset/3`'s `validate_inclusion`.
  defp report_health_route(env, root, app_name) do
    router_path = "lib/#{app_name}_web/router.ex"

    status =
      case DeployBoilerplate.health_route_unpiped(env, router_path) do
        :ok -> "ok"
        {:error, {:no_health_route, _}} -> "no_health_route"
        {:error, {:health_route_piped, _}} -> "health_route_piped"
      end

    Channel.deliver_health_route_status(root, status)
  end

  # Files the scanner claims no role for never sync, which reads exactly like a
  # dead watcher. Logged at `:info` (prod filters `:debug`), only when the set
  # changes.
  @doc """
  Exposed so a test can drive it without a whole sync; the log line is the
  behaviour under test.
  """
  def report_skipped(root) do
    log_unclassified(Environment.new(:local, root), root)
  end

  # Keyed on the root: two checkouts of one project skip different files, and a
  # dedup key shared between them silences the second one's report.
  defp log_unclassified(env, root) do
    paths = Scanner.unclassified(env)
    key = {__MODULE__, :unclassified, root}

    if paths != :persistent_term.get(key, :never_scanned) do
      :persistent_term.put(key, paths)
      report_unclassified(paths, root)
    end
  end

  defp report_unclassified([], root) do
    Logger.info("[CmsHarness] every file under the sync roots of #{root} now has a role")
  end

  defp report_unclassified(paths, root) do
    Logger.info(
      "[CmsHarness] #{length(paths)} file(s) under the sync roots of #{root} match no role " <>
        "and are NOT synced: #{paths |> Enum.take(10) |> Enum.join(", ")}" <>
        if(length(paths) > 10, do: " (+#{length(paths) - 10} more)", else: "") <>
        ". If a requirement says one of these is missing, this is why — it is not the watcher."
    )
  end

  @doc "The `Task.Supervisor` registry name for this checkout's scans/analyzer runs."
  def task_supervisor(root),
    do: {:via, Registry, {CmsHarness.Registry, {:tasks, root}}}
end
