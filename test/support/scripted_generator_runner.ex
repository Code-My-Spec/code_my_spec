defmodule CodeMySpecTest.ScriptedGeneratorRunner do
  @moduledoc """
  Fake `CmsHarness.Projects.Generator.Runner` for exercising
  `CmsHarness.Projects.Generator.run/1`'s own sequencing and skip logic
  without shelling out to `mix` for real.

  `Generator.run/1` calls this from the same process a test calls it from — no
  `Task` in between at this level, only `CmsHarness.WorkingCopyReporter`
  spawns one — so a script set with `Process.put/2` before the call is visible
  to every `cmd/3` invocation the run makes, and invisible to every other
  async test doing the same.

  Unscripted, a call succeeds with empty output and touches nothing on disk —
  fine for a step whose result the test does not care about, wrong for one it
  does. A test asserting on what `mix harness.onboard` would have written
  scripts that step to write it, the same way the real subprocess would have.
  """

  @behaviour CmsHarness.Projects.Generator.Runner

  @key :generator_runner_script

  @doc "Script the next process-local `Generator.run/1` call's commands."
  @spec script((String.t(), String.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})) ::
          :ok
  def script(fun) when is_function(fun, 3) do
    Process.put(@key, fun)
    :ok
  end

  @impl true
  def cmd(cwd, command, args) do
    case Process.get(@key) do
      nil -> {:ok, ""}
      fun -> fun.(cwd, command, args)
    end
  end
end
