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
  # Silent when git cannot answer — a checkout that is not a repository is an
  # ordinary thing for this to meet, and reporting nothing leaves the column
  # nil, which the gate reads as "not judged" rather than as "in sync".
  defp report_git_state(env, root) do
    with {ahead, 0} <- git(env, ["rev-list", "--count", "main..HEAD"]),
         {behind, 0} <- git(env, ["rev-list", "--count", "HEAD..main"]),
         {status, 0} <- git(env, ["status", "--porcelain", "--untracked-files=no"]) do
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
