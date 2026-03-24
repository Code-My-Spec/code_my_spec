defmodule CodeMySpec.AgentTasks.Setup.CredoChecks do
  @moduledoc """
  Setup step: .credo.exs configured with custom check paths.
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()
    credo_path = Path.join(dir, ".credo.exs")

    case File.read(credo_path) do
      {:ok, content} ->
        has_requires =
          String.contains?(content, "credo_checks/framework") and
            String.contains?(content, "credo_checks/local")

        has_eval = String.contains?(content, "credo_checks/framework/checks.exs")

        if has_requires and has_eval,
          do: {:ok, :valid},
          else: {:ok, :invalid, "`#{credo_path}` missing custom check configuration (requires + eval_file)"}

      _ ->
        {:ok, :invalid, "`.credo.exs` not found at `#{credo_path}`"}
    end
  end

  def command(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()

    {:ok, """
    # Configure Credo Custom Checks

    Create local checks directory:
    ```bash
    mkdir -p #{Path.join(dir, ".code_my_spec/credo_checks/local")}
    ```

    Edit `#{Path.join(dir, ".credo.exs")}`:

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
