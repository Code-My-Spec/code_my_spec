defmodule CodeMySpec.AgentTasks.Setup.ProjectCompiles do
  @moduledoc """
  Setup step: project compiles without errors or warnings.
  """

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()

    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, :valid}

      {output, _} ->
        {:ok, :invalid, "Compilation failed in `#{dir}`:\n#{String.slice(output, 0, 500)}"}
    end
  end

  def command(scope, _task) do
    dir = scope.cwd || File.cwd!()

    {:ok, """
    # Fix Compilation Errors

    Run in `#{dir}`:
    ```bash
    mix compile --warnings-as-errors
    ```

    Fix all errors and warnings until compilation passes cleanly.
    """}
  end
end
