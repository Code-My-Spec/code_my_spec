defmodule CodeMySpec.AgentTasks.Setup.ProjectCompiles do
  @moduledoc """
  Setup step: project compiles without errors or warnings.

  Note: This step uses System.cmd directly because compilation
  requires shell execution, which is outside the Environment abstraction.
  The cwd is sourced from scope.environment.cwd.
  """

  def evaluate(scope, _task) do
    dir = scope.environment.cwd

    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, :valid}

      {output, _} ->
        {:ok, :invalid, "Compilation failed:\n#{String.slice(output, 0, 500)}"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Fix Compilation Errors

    ```bash
    mix compile --warnings-as-errors
    ```

    Fix all errors and warnings until compilation passes cleanly.
    """}
  end
end
