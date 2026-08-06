defmodule CmsHarness.TestDatabase do
  @moduledoc """
  A test database per working copy, so the analyzer's answer is about the tree
  it was pointed at.

  ## The failure this exists to stop

  `mix test` uses whatever database `config/test.exs` names, and on a machine
  running several agents that is one database shared by every checkout.
  Whichever one migrated last wins and the others inherit its schema.

  Measured here, same commit, same suite: **36 failures** on the shared database
  and **1** on its own. The whole difference was one column — `conversations.type`,
  `NOT NULL`, added by a branch this checkout does not have. Every insert on this
  branch then died, and the stop hook reported ~25 failures across four test
  files as though this branch had broken them.

  That is worse than slow. The analyzer's verdict is what the harness is *for*,
  and an agent that believes it will start repairing code that was never broken.
  Nothing in the output distinguishes "your code is wrong" from "this database is
  not yours".

  ## Per working copy, not per project

  Two worktrees of one project is the ordinary case — a branch each — and they
  need different schemas at the same time, which is exactly what a project-keyed
  name would deny them. So the partition is derived from the absolute path of the
  working copy.

  ## Degrading rather than guessing

  Setting `MIX_TEST_PARTITION` only isolates a project whose `config/test.exs`
  reads it. Where it does (the Phoenix default, and this repo), the database has
  to exist, so this creates and migrates it first. Where it does not, the name is
  unchanged and this is a no-op.

  If either step fails — no Ecto, no database server, a project that does not
  work this way — no partition is set and the run proceeds exactly as it did
  before. An analyzer that refused to run because it could not manage a database
  would be a worse failure than the one this fixes.
  """

  require Logger

  alias CodeMySpec.Environments

  @doc """
  Environment for a `mix test` in `env`, isolating its database when it can.

  Returns `[]` when isolation is not available, which is the signal to run
  against whatever the project already uses.
  """
  @spec env(Environments.Environment.t()) :: [{String.t(), String.t()}]
  def env(%{cwd: cwd} = environment) when is_binary(cwd) do
    partition = partition_for(cwd)

    case ensure_once(environment, partition) do
      :ok ->
        [{"MIX_TEST_PARTITION", partition}]

      {:error, reason} ->
        # Once per run, at info: a project that does not use Ecto would
        # otherwise log a warning on every sweep forever.
        Logger.info(
          "[CmsHarness] no isolated test database for #{cwd} (#{reason}); " <>
            "using the project's own. Failures may belong to another checkout."
        )

        []
    end
  end

  def env(_environment), do: []

  @doc """
  The partition name for a working copy.

  Short, stable, and derived from the absolute path — two worktrees of one
  project get different databases, and the same worktree gets the same one
  across restarts so the migrate is paid once.
  """
  @spec partition_for(String.t()) :: String.t()
  def partition_for(cwd) do
    digest =
      cwd
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "h#{digest}"
  end

  # Once per partition per harness, because it is not cheap: measured at 37.6s
  # on this repo, and it was on the path of every exunit sweep. Migrations added
  # after the harness started are picked up on its next restart, which is the
  # same moment its code changes anyway.
  #
  # Cached on failure too. A project with no Ecto would otherwise pay two failing
  # `mix` boots before every test run, forever, to reach the same answer.
  defp ensure_once(environment, partition) do
    key = {__MODULE__, partition}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = ensure_database(environment, partition)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp ensure_database(environment, partition) do
    with :ok <- run_mix(environment, partition, ["ecto.create", "--quiet"]) do
      run_mix(environment, partition, ["ecto.migrate", "--quiet"])
    end
  end

  defp run_mix(environment, partition, args) do
    cmd_env =
      [
        {"MIX_ENV", "test"},
        {"MIX_TEST_PARTITION", partition}
      ] ++ Environments.clean_otp_env()

    case Environments.cmd(environment, "mix", args, stderr_to_stdout: true, env: cmd_env) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "mix #{hd(args)} exited #{status}: #{excerpt(output)}"}
    end
  rescue
    exception -> {:error, "mix #{hd(args)} crashed: #{Exception.message(exception)}"}
  end

  defp excerpt(output), do: output |> String.trim() |> String.slice(0, 160)
end
