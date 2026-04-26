defmodule CodeMySpec.AgentTasks.Setup.SpexCase do
  @moduledoc """
  Setup step: the `<App>Spex.Case` module exists at
  `test/support/<app>_spex_case.ex`.

  This is the base ExUnit case template that BDD spec files `use`. It wires
  up Phoenix.ConnTest, Phoenix.LiveViewTest, the SexySpex DSL, and the DB
  sandbox. Think of it as ConnCase for spec files.
  """

  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}

  def check(%Context{} = ctx) do
    case Context.app_name(ctx) do
      nil ->
        {:invalid, "Could not determine app name from `mix.exs`"}

      app ->
        path = Path.join(["test", "support", "#{app}_spex_case.ex"])

        case Context.error(ctx, path, :spex_case_module, "Missing `#{path}`") do
          nil -> :valid
          msg -> {:invalid, msg}
        end
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

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
