defmodule CmsHarness.AnalyzerEnv do
  @moduledoc """
  The environment every analyzer command runs in, so the analyzer stops
  competing with the agent for the same working copy.

  ## What it is for

  The analyzer shells out to `mix` in the same checkout the agent is working
  in. Without separation the two share `_build`, and an agent's own
  `mix compile --force` wipes and rebuilds it underneath a running suite:
  modules vanish mid-run and come back as
  `(module CodeMySpec.Mail.ResendClient is not available)` for a module that
  exists and was never touched. 14 of 46 reported failures on one occasion,
  indistinguishable from a real missing dependency — the natural response is to
  add code that is already there.

  It is also how a run gets wedged. An analyzer waiting on the build lock holds
  the single-flight guard, and every stop inside that window is refused. That
  cost five consecutive stops on a finding already fixed and pushed.

  `Runners.from_raw/2` now *detects* the lost-build signature and fails the run
  rather than reporting phantom failures. This removes the cause.

  ## Under `_build`, not beside it

  `_build/analyzer` rather than `_build_analyzer`, so it inherits the existing
  gitignore. A sibling directory would need its own entry and would be
  committed by the first person who forgot.

  Mix appends the env, so the analyzer's tree is `_build/analyzer/test` and the
  agent's stays `_build/test`. They no longer touch.

  ## The cost, stated plainly

  One full compile per working copy, the first time the analyzer runs, and the
  disk for a second build tree. That is the trade for the analyzer's answer
  being about the tree it was pointed at rather than about whatever the agent
  was doing at the time.

  The database was already separate: `TestDatabase.env/1` sets
  `MIX_TEST_PARTITION` to a digest of the working copy, while an agent running
  `mix test` by hand leaves it unset and `config/test.exs` derives a name from
  the worktree instead. Different databases, by accident of two mechanisms
  rather than by design, but different.
  """

  alias CmsHarness.TestDatabase
  alias CodeMySpec.Environments.Environment

  @build_subdir "_build/analyzer"

  @doc """
  Extra environment for an analyzer command in `environment`.

  Every source gets the same value — compiler, credo, exunit and spex — because
  isolating some of them would mean the analyzer compiled into one tree and
  tested from another, which is slower than sharing and no safer.
  """
  @spec extra_env(Environment.t()) :: [{String.t(), String.t()}]
  def extra_env(%{cwd: cwd} = environment) when is_binary(cwd) do
    # Passed on as well as returned: TestDatabase shells out to `mix` itself to
    # create and migrate, and those took the default build path — the agent's.
    build_env = [{"MIX_BUILD_PATH", build_path(cwd)}]

    build_env ++ TestDatabase.env(environment, build_env)
  end

  def extra_env(environment), do: TestDatabase.env(environment)

  @doc "Where the analyzer builds, for a working copy at `cwd`."
  @spec build_path(String.t()) :: String.t()
  def build_path(cwd), do: Path.join(Path.expand(cwd), @build_subdir)
end
