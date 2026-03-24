defmodule CodeMySpec.AgentTasks.Init.Postgresql do
  @moduledoc """
  Init step: verify PostgreSQL is available.
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = working_dir(scope)

    case System.cmd("psql", ["--version"], cd: dir, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, :valid}
      _ -> {:ok, :invalid, "PostgreSQL not found"}
    end
  end

  def command(_scope, _session, _opts \\ []) do
    {:ok, """
    # Install PostgreSQL

    macOS:
    ```bash
    brew install postgresql@16
    brew services start postgresql@16
    ```

    Verify: `psql --version`
    """}
  end

  defp working_dir(scope) do
    scope.cwd || File.cwd!()
  end
end
