defmodule CodeMySpec.AgentTasks.Setup.TestSupportNamespace do
  @moduledoc """
  Setup step: ConnCase/DataCase use AppTest namespace.
  """

  @test_support_files ["conn_case.ex", "data_case.ex"]

  def evaluate(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()

    case extract_app_name(dir) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `#{Path.join(dir, "mix.exs")}`"}

      app_name ->
        mod = Macro.camelize(app_name)
        test_ns = "#{mod}Test"

        wrong =
          @test_support_files
          |> Enum.reject(fn file ->
            path = Path.join([dir, "test", "support", file])

            case File.read(path) do
              {:ok, content} -> String.contains?(content, "defmodule #{test_ns}.")
              {:error, :enoent} -> true
              _ -> false
            end
          end)

        if wrong == [],
          do: {:ok, :valid},
          else: {:ok, :invalid, "#{Enum.join(wrong, ", ")} not in `#{test_ns}` namespace under `#{Path.join([dir, "test", "support"])}/`"}
    end
  end

  def command(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()
    app_name = extract_app_name(dir) || "your_app"
    mod = Macro.camelize(app_name)

    {:ok, """
    # Move Test Support to #{mod}Test Namespace

    Rename in `#{Path.join([dir, "test", "support", "conn_case.ex"])}`:
    `#{mod}Web.ConnCase` → `#{mod}Test.ConnCase`

    Rename in `#{Path.join([dir, "test", "support", "data_case.ex"])}`:
    `#{mod}.DataCase` → `#{mod}Test.DataCase`

    Update all test files that `use` these modules.
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
end
