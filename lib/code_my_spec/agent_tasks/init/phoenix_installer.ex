defmodule CodeMySpec.AgentTasks.Init.PhoenixInstaller do
  @moduledoc """
  Init step: verify Phoenix installer (phx_new) is available.

  Asks the active Elixir/mix toolchain via `mix phx.new --version` so the
  check honors version managers like asdf, where archives live under each
  installed Elixir version (not in `~/.mix/archives`).
  """

  def evaluate(scope, _task) do
    dir = working_dir(scope)

    case System.cmd("mix", ["phx.new", "--version"], cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "Phoenix installer"),
          do: {:ok, :valid},
          else: {:ok, :invalid, "Unexpected output from `mix phx.new --version`: #{String.trim(output)}"}

      {output, _} ->
        {:ok, :invalid,
         "phx_new archive not available: #{String.trim(output)}. Run `mix archive.install hex phx_new`."}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Install Phoenix Installer

    ```bash
    mix archive.install hex phx_new
    ```

    Verify: `mix phx.new --version`
    """}
  end

  defp working_dir(scope) do
    scope.cwd || File.cwd!()
  end
end
