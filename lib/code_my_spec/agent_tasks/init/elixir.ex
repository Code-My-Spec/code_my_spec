defmodule CodeMySpec.AgentTasks.Init.Elixir do
  @moduledoc """
  Init step: verify Elixir 1.18+ is installed.
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = working_dir(scope)

    case System.cmd("elixir", ["--version"], cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        if Regex.match?(~r/Elixir\s+(1\.(1[89]|[2-9]\d)|[2-9]\.)/, output),
          do: {:ok, :valid},
          else: {:ok, :invalid, "Elixir version too old: #{String.trim(output)}"}

      _ ->
        {:ok, :invalid, "Elixir not found"}
    end
  end

  def command(_scope, _session, _opts \\ []) do
    {:ok, """
    # Install Elixir 1.18+

    Install using asdf (recommended):
    ```bash
    asdf plugin add elixir
    asdf install elixir 1.18.1
    asdf global elixir 1.18.1
    ```

    Or Homebrew (macOS):
    ```bash
    brew install elixir
    ```

    Verify: `elixir --version`
    """}
  end

  defp working_dir(scope) do
    scope.cwd || File.cwd!()
  end
end
