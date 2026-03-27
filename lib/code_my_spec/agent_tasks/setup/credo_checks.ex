defmodule CodeMySpec.AgentTasks.Setup.CredoChecks do
  @moduledoc """
  Setup step: .credo.exs configured with custom check paths.
  """

  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment

    case Environments.read_file(env, ".credo.exs") do
      {:ok, content} ->
        has_requires =
          String.contains?(content, "credo_checks/framework") and
            String.contains?(content, "credo_checks/local")

        has_eval = String.contains?(content, "credo_checks/framework/checks.exs")

        if has_requires and has_eval,
          do: {:ok, :valid},
          else: {:ok, :invalid, "`.credo.exs` missing custom check configuration (requires + eval_file)"}

      _ ->
        {:ok, :invalid, "`.credo.exs` not found"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Configure Credo Custom Checks

    Create local checks directory:
    ```bash
    mkdir -p .code_my_spec/credo_checks/local
    ```

    Edit `.credo.exs`:

    ```elixir
    requires: [
      ".code_my_spec/credo_checks/framework/**/*.ex",
      ".code_my_spec/credo_checks/local/**/*.ex"
    ],
    checks: %{
      extra:
        if(File.exists?(".code_my_spec/credo_checks/framework/checks.exs"),
          do: elem(Code.eval_file(".code_my_spec/credo_checks/framework/checks.exs"), 0),
          else: []
        )
    }
    ```
    """}
  end
end
