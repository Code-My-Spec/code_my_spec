defmodule CodeMySpec.AgentTasks.Setup.TestBoundaries do
  @moduledoc """
  Setup step: boundary namespace modules exist in test/support/.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment

    case Helpers.extract_app_name(env) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `mix.exs`"}

      app_name ->
        spex_path = Path.join(["test", "support", "#{app_name}_spex.ex"])
        test_path = Path.join(["test", "support", "#{app_name}_test_boundary.ex"])

        spex_ok = file_contains?(env, spex_path, "use Boundary")
        test_ok = file_contains?(env, test_path, "use Boundary")

        cond do
          not spex_ok and not test_ok ->
            {:ok, :invalid, "Missing both `#{spex_path}` and `#{test_path}` with `use Boundary`"}
          not spex_ok ->
            {:ok, :invalid, "Missing `#{spex_path}` with `use Boundary`"}
          not test_ok ->
            {:ok, :invalid, "Missing `#{test_path}` with `use Boundary`"}
          true ->
            {:ok, :valid}
        end
    end
  end

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    mod = Macro.camelize(app_name)

    {:ok, """
    # Configure Test Boundaries

    Create `test/support/#{app_name}_spex.ex`:
    ```elixir
    defmodule #{mod}Spex do
      use Boundary, top_level?: true, deps: [#{mod}Test, #{mod}Web]
    end
    ```

    Create `test/support/#{app_name}_test_boundary.ex`:
    ```elixir
    defmodule #{mod}Test do
      use Boundary, top_level?: true, deps: [#{mod}]
    end
    ```
    """}
  end

  defp file_contains?(env, path, needle) do
    case Environments.read_file(env, path) do
      {:ok, content} -> String.contains?(content, needle)
      _ -> false
    end
  end
end
