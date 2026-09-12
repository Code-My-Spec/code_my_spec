defmodule CmsHarness.Sync do
  @moduledoc """
  Scan a working copy and hand the manifest to the channel.

  Runs under the project's own `Task.Supervisor`, not in the channel process. A
  full scan of a few thousand files reads and hashes every one of them; doing
  that inline would stall the socket that holds the project's lease, and a
  stalled socket is a lease the server cannot tell from a live one.

  The scan itself is `CodeMySpec.Files.Scanner` — the same code the server runs,
  from `cms_scan`, so the two cannot disagree about what a file is.
  """

  require Logger

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Project.ChannelClient
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
        # Loudly: a sync that silently does not happen looks exactly like a
        # project with nothing to do.
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
    report_git_state(env, project.root)
    report_preview_health(env, project.root)

    case Scanner.observe(env, read_model) do
      {:error, reason} ->
        Logger.error(
          "[CmsHarness] could not scan #{project.root}: #{inspect(reason)}. Sending " <>
            "nothing — a manifest is the whole truth about a working copy, so an empty " <>
            "one tells the server every file here was deleted."
        )

        :ok

      # Handed on, not refused here. A tree that walks clean and yields nothing
      # is a real state — delete a project's last tracked file and this is what
      # it looks like — and refusing at this level would leave the server
      # holding rows for files that are gone, which is the defect this manifest
      # design exists to prevent. Said at `:error` because for an established
      # project it is almost always a wrong or unreadable root.
      #
      # It does not claim the manifest was sent. `ChannelClient` has its own
      # guard on `{:observations, []}` and usually refuses, so this used to
      # announce "Sending the empty manifest, which will remove every row"
      # immediately before the next line said "so nothing was sent" — one of
      # them was always wrong, and a reader had to know which layer won to tell
      # which. Issue 03ea1ee5. Say what was found; let the layer that decides
      # say what it decided.
      {:ok, []} ->
        Logger.error(
          "[CmsHarness] scanned #{project.root} and found no trackable files. For an " <>
            "established project that is almost always a wrong or unreadable root — " <>
            "check the root and the sync roots. Whether an empty manifest is sent is " <>
            "the channel's call, and it says so on the next line."
        )

        ChannelClient.deliver_observations(project.root, [])

      {:ok, observations} ->
        Logger.info(
          "[CmsHarness] scanned #{length(observations)} files in #{project.root} " <>
            "in #{System.monotonic_time(:millisecond) - started}ms"
        )

        log_unclassified(env, project.root)

        ChannelClient.deliver_observations(project.root, observations)
    end
  end

  # A server-side deploy-readiness check has no real way to read this
  # project's `mix.exs` — `scope.environment` there resolves through
  # `Resources.project_scope/2`'s fallback to `Environment.new(:local,
  # project.local_path)`, a path on *this* machine, not the server's (see
  # `CodeMySpec.Provisioning.Steps.app_path/1`). This machine can read it
  # directly, so it does, on every sync — self-healing a `module_name` that
  # was never set (or was set wrong) without waiting on a separate onboarding
  # step to have asked for it correctly.
  defp report_app_name(env, root) do
    case Environments.mix_exs_app_name(env) do
      # `project.module_name` stores the CamelCase form — `app_path/1`'s
      # fallback un-derives it back to this same snake_case name via
      # `Macro.underscore/1` — so this is the inverse of that, not a second
      # format decision.
      name when is_binary(name) ->
        ChannelClient.deliver_module_name(root, Macro.camelize(name))
        report_health_route(env, root, name)

      nil ->
        :ok
    end
  end

  # Whether the application this checkout runs is answering.
  #
  # Against `preview_url`, which is the address QA opens. A check against a
  # local port would pass while the thing anyone actually browses is dead, and
  # the port is known only to the machine running the app anyway — the URL is
  # in this checkout's own `.cms_harness.json`.
  #
  # `/health` when the project has one. `health_route_status` records whether it
  # does; where it does not, the root answers the same question less precisely,
  # and asking for a path that is not there would read every app as erroring.
  #
  # Silent when no preview is recorded. A checkout with no preview address has
  # nothing to be up, and reporting `down` for it would put every un-previewed
  # copy behind a gate it cannot clear.
  @doc """
  Measure this checkout's preview and report it, independent of a scan.

  Public because a scan is the wrong clock for it. Everything else `run/2`
  reports — the app name, the head commit, the git state — changes only when
  the disk changes, so measuring it when the disk changes is exactly right. An
  application does not. It crashes while nobody is editing, and it recovers
  while nobody is editing.

  Measured: Broken Oaths' preview answered 200 on both the port and the tunnel
  while `preview_status` still said `down`, because the row was last written by
  a sync and no file had changed since. `code_on_running_copy` refuses on that
  column, so the story stayed shut on a fact that had stopped being true — and
  the inverse is worse, an app that died after the last sync reads as serving
  and QA is sent to it.
  """
  @spec measure_preview(String.t()) :: :ok
  def measure_preview(root) do
    :local |> Environment.new(root) |> report_preview_health(root)
  end

  @doc """
  Re-measure what `code_on_running_copy` reads, independent of a scan.

  Both facts the gate reads change without any file changing, and only one of
  them was on a clock. Preview health got its own timer because an application
  crashes and recovers while nobody is editing. Git state was left on the scan
  clock, and that was half a fix: **a promotion is exactly the event that moves
  a checkout's relationship to main without touching a file in it.**

  Measured. A promotion merged this copy's work into the running checkout at
  05:25; at 06:01 git said `ahead=0 behind=0` and the row still said `ahead=3`,
  last reported 04:51 — seventy minutes stale, because nothing had edited a file
  since. The gate read that and went on offering `PromoteWork` for a story whose
  code was already promoted, serving, and green. The agent reported it as "the
  graph lags a sync cycle"; it is not a lag, it is an event the clock never sees.

  Cheap enough to sit beside the preview check: three `git` invocations against
  a local checkout, once a minute.
  """
  @spec measure_checkout(String.t()) :: :ok
  def measure_checkout(root) do
    env = Environment.new(:local, root)

    report_git_state(env, root)
    report_preview_health(env, root)
  end

  @doc """
  Re-measure what the machine this checkout runs on is carrying, independent
  of a scan and on its own clock, for the same reason `measure_checkout/1` is:
  a saturated box gets more or less saturated while nobody touches a file.

  Story 1057, criterion 3324. A harness already reports facts it observes
  about its checkout — its preview, its tools, its head commit — and never
  what it runs on, so a saturated machine read as several individually slow
  agents, and the obvious remedy (restart them) is the one thing that makes a
  saturated box worse.

  Not through `Environments` / `CodeMySpec.Environments.cmd`: that abstraction
  exists to reach a *checkout* — local, docker, remote — and the box a harness
  runs on is always this one, regardless of which environment a project's code
  happens to run in. Plain `System.cmd` against whatever this platform's own
  tools are, same as `CmsHarness.WorkingCopies.Create`'s `git worktree add`.

  `:os_mon` (`:cpu_sup.avg1/0`, `:memsup.get_system_memory_data/0`) is the
  obvious way to read load and memory and is not available here —
  `extra_applications` never starts it, and adding an OTP application would
  need a deliberate restart of every running dev server, not a quiet mix.exs
  edit that a live session would never pick up.

  Silent on whatever a field this platform cannot answer, the same as
  `report_git_state/2` is on a checkout that is not a repository: a box this
  has not been taught to read is the ordinary case for a platform nobody has
  run it on yet, not a reason to crash the sync loop that carries every other
  fact this checkout reports.
  """
  @spec measure_machine_load(String.t()) :: :ok
  def measure_machine_load(root) do
    case machine_load() do
      load when map_size(load) > 0 -> ChannelClient.deliver_machine_load(root, load)
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

  # `:logical_processors_available` over `:logical_processors`: the latter
  # counts what the hardware has, the former what the BEAM was actually given
  # (a cgroup/taskset limit on a shared box), which is the number
  # `Machinery.saturated?/2` compares `load_average` against.
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

  # "{ 1.23 2.45 2.10 }\n" — one-minute, five-minute, fifteen-minute. The
  # first is the one `over_committed?/2` wants.
  #
  # `Float.parse/1` rather than `String.to_float/1`, matching the Linux twin:
  # the pattern above captures digits and dots, so a reading with no decimal
  # point yields "31", and `String.to_float("31")` raises. This runs inside a
  # detached task, so that would fail with nothing to report it and the machine
  # would go back to "has not reported what it is carrying" leaving no trace of
  # why. macOS always prints two decimals, so this is about keeping the two
  # parsers honest rather than a failure anybody has seen.
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

  # Free plus speculative pages, not raw free pages. macOS keeps a large file
  # cache in inactive pages by design, and a script that stopped there would
  # read a machine that has been up for an hour as perpetually low on memory.
  # Free pages are idle; speculative pages are read-ahead nothing has touched
  # yet — both give themselves back with no write-back, which is what "free"
  # needs to mean for `short_of_memory?/1`'s threshold to be a real signal
  # rather than noise off every macOS box that has been running a while.
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

  # `/proc` directly rather than shelling out to `uptime`/`free`: both files
  # are always present on a real Linux kernel, `File.read/1` already answers
  # `{:error, _}` instead of raising on whatever is not, and it needs no
  # cassette to test. The dev box is macOS — this exists so a harness running
  # on a Linux box reports the same facts rather than reporting nothing.
  defp linux_load do
    Map.merge(linux_load_average(), linux_memory_free_mb())
  end

  defp linux_load_average do
    case File.read("/proc/loadavg") do
      {:ok, contents} -> parse_linux_loadavg(contents)
      {:error, _} -> %{}
    end
  end

  # "0.08 0.03 0.01 1/512 12345\n" — the first figure is the one-minute
  # average, same as `parse_darwin_loadavg/1`'s first field.
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

  # `MemAvailable` over `MemFree`, for the same reason the darwin side adds
  # speculative pages back onto free ones: Linux also keeps a large reclaimable
  # page cache, and `MemAvailable` is the kernel's own estimate of what a new
  # process could get without swapping — `MemFree` alone reads a healthy box as
  # perpetually starved.
  defp parse_linux_meminfo(contents) do
    case Regex.run(~r/^MemAvailable:\s*(\d+) kB/m, contents) do
      [_, kb] -> %{"memory_free_mb" => div(String.to_integer(kb), 1024)}
      _ -> %{}
    end
  end

  defp report_preview_health(env, root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{preview_url: url}} when is_binary(url) and url != "" ->
        status = preview_status(env, url)
        Logger.info("[CmsHarness] #{url} is #{status}")
        ChannelClient.deliver_preview_status(root, status)

      _ ->
        :ok
    end
  end

  # `curl` through the environment rather than `Req` here: this module already
  # reaches the outside world that way, and the harness must not care whether
  # the address is a tunnel, a proxy or a port.
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

  # Codes the edge answers with when the request never reached an application.
  #
  # Every preview address is a Cloudflare tunnel, so "nothing is running" does
  # not arrive as a refused connection — it arrives as a 530 carrying Argo error
  # 1033, "no origin connected". Measured on three live previews the day this
  # was written: two checkouts with no app running returned 530, and the gate
  # read them as `erroring` and let QA through to a Cloudflare error page.
  #
  # Which is the failure this whole path exists to prevent, surviving one layer
  # down. `erroring` has to mean the application answered and failed, because
  # that is the one QA should be sent to meet; an origin that is not there is
  # `down` however the edge phrases it.
  #
  # 502 is here for the same reason and is worth stating: Phoenix answers its
  # own failures with 500, so a 502 on this path is a proxy that could not reach
  # anything, not an application.
  @no_origin [502, 520, 521, 522, 523, 524, 525, 526, 527, 530]

  @doc """
  What an HTTP status from a preview address says about the application.

  Public because it is the whole of the judgement — the rest of this path just
  carries the answer — and because it got the judgement wrong in a way nothing
  else could have caught.
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

  # Whether this checkout's work is on main, main's work is on it, and its tree
  # is clean — the three facts `code_on_running_copy` gates on.
  #
  # Measured here for the same reason `report_head_commit/2` is: this machine
  # can run `git` in the real checkout, and the server cannot. A requirement
  # graph is computed inside the channel process for a harness-served project,
  # so asking the machine at gate time would be the graph waiting on the
  # connection it is being computed on.
  #
  # Both counts come from this checkout alone. A worktree shares an object store
  # with the checkout it was made from, so `main` resolves here and needs no
  # remote and no second root.
  #
  # `--untracked-files=no` for the reason `just refresh` already documents:
  # refusing on untracked files means refusing essentially always, which is the
  # same as not having the check. A build is made of what is committed and what
  # is modified, not of scratch files beside them.
  #
  # `--ignore-submodules=all` for the same reason `just refresh`'s own dirty
  # check already carries it: `.code_my_spec` is a submodule, and a QA agent
  # writes into it continuously for the one-to-two hours it works — a brief
  # drafted, a screenshot captured, `prompt.md` regenerated on every task. None
  # of that touches this superproject's own tracked files, but plain
  # `git status` reports a dirty submodule as a modified path here regardless,
  # which is what made `tree_dirty` true (and `code_on_running_copy` refuse)
  # for a copy's entire QA session (c97bb142). The superproject's own merge
  # safety was never in question — a submodule's internal working tree is not
  # part of what `git merge` here would touch.
  #
  # Silent when git cannot answer — a checkout that is not a repository is an
  # ordinary thing for this to meet, and reporting nothing leaves the column
  # nil, which the gate reads as "not judged" rather than as "in sync".
  defp report_git_state(env, root) do
    with {ahead, 0} <- git(env, ["rev-list", "--count", "main..HEAD"]),
         {behind, 0} <- git(env, ["rev-list", "--count", "HEAD..main"]),
         {status, 0} <-
           git(env, ["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"]) do
      ChannelClient.deliver_git_state(root, %{
        "ahead" => to_count(ahead),
        "behind" => to_count(behind),
        "dirty" => String.trim(status) != ""
      })
    else
      _ -> :ok
    end
  end

  defp git(env, args), do: Environments.cmd(env, "git", args, stderr_to_stdout: true)

  defp to_count(out) do
    case Integer.parse(String.trim(out)) do
      {n, _} -> n
      :error -> 0
    end
  end

  # `Steps.image_tag/2` needs the checkout's real `git rev-parse HEAD` to tag a
  # build with — the same reachability gap `app_path/1` has with `mix.exs`.
  # This machine can run `git` in the real checkout, so it does, on every
  # sync, and reports the SHA for a harness-only project to fall back to.
  defp report_head_commit(env, root) do
    case Environments.cmd(env, "git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> ChannelClient.deliver_head_commit(root, String.trim(sha))
      _ -> :ok
    end
  end

  # `health_route_unpiped/2` is a content check — the server has no real way
  # to read a harness-only project's `router.ex`/`endpoint.ex` at all, the
  # same reason `app_path/1` stopped depending on `module_name` ever having
  # arrived through onboarding. This machine can read them directly, so it
  # runs the exact same check `Generators.audit/2` would, on every sync, and
  # reports the verdict — `Project.changeset/3`'s `validate_inclusion` is
  # what fixes these three strings to match what `Generators` expects back.
  defp report_health_route(env, root, app_name) do
    router_path = "lib/#{app_name}_web/router.ex"

    status =
      case DeployBoilerplate.health_route_unpiped(env, router_path) do
        :ok -> "ok"
        {:error, {:no_health_route, _}} -> "no_health_route"
        {:error, {:health_route_piped, _}} -> "health_route_piped"
      end

    ChannelClient.deliver_health_route_status(root, status)
  end

  # What the scan walked past.
  #
  # `stream_files/1` drops anything `classify/1` does not claim, and it used to
  # drop it in silence. That silence is the most expensive missing line in this
  # system: an unclassified file never syncs, so the scan reports a *constant*
  # count while the agent keeps writing, and the requirement gating on it says
  # the file is missing while it sits on disk. It reads exactly like a dead
  # watcher, and three drills were spent proving that watchers scanning every
  # forty-five seconds were, in fact, fine.
  #
  # At `:info`, because the release runs prod config and `:debug` is filtered —
  # a diagnostic nobody can see is worse than none, since it reads as evidence
  # that nothing was skipped. Logged only when the set *changes*, so a project
  # with the usual ignorable scaffolding says this once rather than every ninety
  # seconds, and a file that newly stops being tracked says so the moment it
  # does.
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
