defmodule CodeMySpec.AgentTasks.Setup.TestSupportNamespace do
  @moduledoc """
  Setup step: ConnCase/DataCase use AppTest namespace.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.Environments

  @test_support_files ["conn_case.ex", "data_case.ex"]

  def evaluate(scope, _task) do
    env = scope.environment

    case Helpers.extract_app_name(env) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `mix.exs`"}

      app_name ->
        mod = Macro.camelize(app_name)
        test_ns = "#{mod}Test"

        wrong =
          @test_support_files
          |> Enum.reject(fn file ->
            path = Path.join(["test", "support", file])

            case Environments.read_file(env, path) do
              {:ok, content} -> String.contains?(content, "defmodule #{test_ns}.")
              {:error, :enoent} -> true
              _ -> false
            end
          end)

        if wrong == [],
          do: {:ok, :valid},
          else: {:ok, :invalid, "#{Enum.join(wrong, ", ")} not in `#{test_ns}` namespace under `test/support/`"}
    end
  end

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    mod = Macro.camelize(app_name)

    {:ok, """
    # Move Test Support to #{mod}Test Namespace

    Rename in `test/support/conn_case.ex`:
    `#{mod}Web.ConnCase` → `#{mod}Test.ConnCase`

    Rename in `test/support/data_case.ex`:
    `#{mod}.DataCase` → `#{mod}Test.DataCase`

    Update all test files that `use` these modules.
    """}
  end
end
