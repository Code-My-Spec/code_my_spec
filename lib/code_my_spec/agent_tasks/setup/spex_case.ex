defmodule CodeMySpec.AgentTasks.Setup.SpexCase do
  @moduledoc """
  Setup step: the `<App>Spex.Case` module exists at
  `test/support/<app>_spex_case.ex`.

  This is the base ExUnit case template that BDD spec files `use`. It wires
  up Phoenix.ConnTest, Phoenix.LiveViewTest, the SexySpex DSL, and the DB
  sandbox. Think of it as ConnCase for spec files.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment

    case Helpers.extract_app_name(env) do
      nil ->
        {:ok, :invalid, "Could not determine app name from `mix.exs`"}

      app_name ->
        mod = Macro.camelize(app_name)
        path = Path.join(["test", "support", "#{app_name}_spex_case.ex"])

        required = [
          "defmodule #{mod}Spex.Case",
          "use SexySpex",
          "import Phoenix.LiveViewTest"
        ]

        case Environments.read_file(env, path) do
          {:ok, content} ->
            missing = Enum.reject(required, &String.contains?(content, &1))

            if missing == [] do
              {:ok, :valid}
            else
              {:ok, :invalid, "`#{path}` missing: #{Enum.join(missing, ", ")}"}
            end

          {:error, :enoent} ->
            {:ok, :invalid, "Missing `#{path}`"}

          _ ->
            {:ok, :invalid, "Cannot read `#{path}`"}
        end
    end
  end

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    mod = Macro.camelize(app_name)

    {:ok, """
    # Create Spex Case Module

    Create `test/support/#{app_name}_spex_case.ex`:

    ```elixir
    defmodule #{mod}Spex.Case do
      @moduledoc \"\"\"
      Base case for spex (BDD spec) tests.

      Wires up Phoenix.ConnTest for HTTP assertions, Phoenix.LiveViewTest
      for driving LiveViews, the SexySpex DSL (spex/scenario/given_/when_/then_),
      and the DB sandbox.
      \"\"\"
      use ExUnit.CaseTemplate

      using do
        quote do
          @endpoint #{mod}Web.Endpoint

          use #{mod}Web, :verified_routes
          use SexySpex

          import Plug.Conn
          import Phoenix.ConnTest
          import Phoenix.LiveViewTest
          import #{mod}Spex.Case
        end
      end

      setup tags do
        #{mod}Test.DataCase.setup_sandbox(tags)
        {:ok, conn: Phoenix.ConnTest.build_conn()}
      end
    end
    ```

    Spec files then start with `use #{mod}Spex.Case`.
    """}
  end
end
