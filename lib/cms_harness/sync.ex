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
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel

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

    observations = Scanner.observe(env, read_model)

    Logger.info(
      "[CmsHarness] scanned #{length(observations)} files in #{project.root} " <>
        "in #{System.monotonic_time(:millisecond) - started}ms"
    )

    log_unclassified(env, project.root)

    ChannelClient.deliver_observations(project.root, observations)
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
  @doc false
  # Exposed so a test can drive it without a whole sync; the log line is the
  # behaviour under test.
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

  @doc false
  def task_supervisor(root),
    do: {:via, Registry, {CmsHarness.Registry, {:tasks, root}}}
end
