defmodule CmsHarness.TestDatabase do
  @moduledoc """
  A test database per working copy, so the analyzer's answer is about the tree
  it was pointed at.

  One shared test database means whichever checkout migrated last decides
  everyone's schema, and the analyzer reports another branch's columns as this
  branch's failures. So the partition is per working copy, not per project:
  two worktrees of one project need different schemas at once.

  This module only names the database. It never creates or migrates one:
  `Mix.Tasks.Cms.CheckTestMigrations` does that in-VM, in `MIX_ENV=test`,
  before the suite starts. See knowledge/harness, "Test databases".
  """

  alias ClientUtils.Harness.Onboarding

  @doc """
  Environment for a `mix test` in `env` — the partition name, and nothing else.

  Returns `[]` for an environment with no working directory, which is the signal
  to run against whatever the project already uses.

  `build_env` is accepted and ignored.
  """
  @spec env(
          CodeMySpec.ExecutionContexts.ExecutionContext.t(),
          [{String.t(), String.t()}],
          String.t() | nil
        ) ::
          [{String.t(), String.t()}]
  def env(environment, build_env \\ [], source \\ nil)

  def env(%{cwd: cwd}, _build_env, source) when is_binary(cwd) do
    [{"MIX_TEST_PARTITION", partition_for(cwd, source)}]
  end

  def env(_environment, _build_env, _source), do: []

  @doc """
  The partition name for a working copy — **read, never derived**.

  Reads through `ClientUtils.Harness.Onboarding.resolve_partition/2`, the same
  recorded-only lookup `resolve_partition!/2` wraps, and raises this project's
  own remedy for a copy that has none: `resolve_partition!/2`'s own message
  names a bare `mix harness.onboard`, which is correct for a generated
  application but not this one — CodeMySpec's own task is namespaced
  `mix cms.harness.onboard` and takes the directory as an argument, the same
  as `CmsHarness.HookDecision`'s `:not_onboarded` explanation already gives
  (ba5a1f09).

  One path, deliberately: no derive-on-miss fallback here, which would keep a
  second copy of the algorithm alive.
  """
  @spec partition_for(String.t()) :: String.t()
  def partition_for(cwd) do
    case Onboarding.resolve_partition(cwd) do
      {:ok, partition} ->
        partition

      {:error, :not_onboarded} ->
        raise """
        #{cwd} has no recorded test partition, so it has not been onboarded.

        Run: mix cms.harness.onboard #{cwd}
        """
    end
  end

  @doc """
  The partition name for a working copy and one analyzer source.

  Each suite that can run concurrently gets its own; anything else keeps the
  shared one.

    <partition>    the interactive session's `mix test`
    <partition>s   the analyzer's spex run
    <partition>a   the analyzer's exunit run

  The analyzer's exunit and spex run concurrently, and the agent's own
  `mix test` (its partition exported into the session by onboarding) can run
  beside either; a shared database lets one suite's truncates and rows fail
  another's tests. Each new partition costs one create and migrate per copy.

  A stopgap: `mix test` arbitration is meant to move into the analyzer.

  A suffix, not a separate digest, so `h1a2b3c4d`, `h1a2b3c4ds` and
  `h1a2b3c4da` read as one working copy.
  """
  @spec partition_for(String.t(), String.t() | nil) :: String.t()
  def partition_for(cwd, "spex"), do: partition_for(cwd) <> "s"
  def partition_for(cwd, "exunit"), do: partition_for(cwd) <> "a"
  def partition_for(cwd, _source), do: partition_for(cwd)

  @doc "Every partition a working copy's runs use: the session's, exunit's and spex's."
  @spec partitions(String.t()) :: [String.t()]
  def partitions(cwd), do: Enum.map([nil, "exunit", "spex"], &partition_for(cwd, &1))
end
