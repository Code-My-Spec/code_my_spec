defmodule CodeMySpec.AgentTasks.Setup.TestBoundaries do
  @moduledoc """
  Setup step: boundary namespace modules exist in test/support/.
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()

    case extract_app_name(dir) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `#{Path.join(dir, "mix.exs")}`"}

      app_name ->
        spex_path = Path.join([dir, "test", "support", "#{app_name}_spex.ex"])
        test_path = Path.join([dir, "test", "support", "#{app_name}_test_boundary.ex"])

        spex_ok = file_contains?(spex_path, "use Boundary")
        test_ok = file_contains?(test_path, "use Boundary")

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

  def command(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()
    app_name = extract_app_name(dir) || "your_app"
    mod = Macro.camelize(app_name)

    {:ok, """
    # Configure Test Boundaries

    Create `#{Path.join([dir, "test", "support", "#{app_name}_spex.ex"])}`:
    ```elixir
    defmodule #{mod}Spex do
      use Boundary, top_level?: true, deps: [#{mod}Test, #{mod}Web]
    end
    ```

    Create `#{Path.join([dir, "test", "support", "#{app_name}_test_boundary.ex"])}`:
    ```elixir
    defmodule #{mod}Test do
      use Boundary, top_level?: true, deps: [#{mod}]
    end
    ```
    """}
  end

  defp extract_app_name(dir) do
    case File.read(Path.join(dir, "mix.exs")) do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end
      _ -> nil
    end
  end

  defp file_contains?(path, needle) do
    case File.read(path) do
      {:ok, content} -> String.contains?(content, needle)
      _ -> false
    end
  end
end
