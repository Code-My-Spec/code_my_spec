defmodule CodeMySpec.AgentTasks.Setup.CredoChecks do
  @moduledoc """
  Setup step: .credo.exs configured with custom check paths.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, ".credo.exs", :custom_checks, "`.credo.exs` not found") do
      nil -> :valid
      msg -> {:invalid, msg}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

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
