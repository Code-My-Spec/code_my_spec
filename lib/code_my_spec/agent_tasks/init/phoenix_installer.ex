defmodule CodeMySpec.AgentTasks.Init.PhoenixInstaller do
  @moduledoc """
  Init step: verify Phoenix installer (phx_new) is available.
  """

  def evaluate(scope, _task) do
    dir = working_dir(scope)

    case System.cmd("mix", ["archive"], cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "phx_new"),
          do: {:ok, :valid},
          else: {:ok, :invalid, "phx_new archive not installed"}

      _ ->
        {:ok, :invalid, "Could not check mix archives"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Install Phoenix Installer

    ```bash
    mix archive.install hex phx_new
    ```

    Verify: `mix archive | grep phx_new`
    """}
  end

  defp working_dir(scope) do
    scope.cwd || File.cwd!()
  end
end
