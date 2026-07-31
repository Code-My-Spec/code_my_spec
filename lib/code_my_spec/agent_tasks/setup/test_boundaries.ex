defmodule CodeMySpec.AgentTasks.Setup.TestBoundaries do
  @moduledoc """
  Setup step: boundary namespace modules exist in test/support/.
  """

  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}

  def check(%Context{} = ctx) do
    case Context.app_name(ctx) do
      nil -> {:invalid, "Could not determine app name from `mix.exs`"}
      app -> check_files(ctx, app)
    end
  end

  defp check_files(ctx, app) do
    spex_path = Path.join(["test", "support", "#{app}_spex.ex"])
    test_path = Path.join(["test", "support", "#{app}_test_boundary.ex"])

    spex_err = Context.error(ctx, spex_path, :has_use_boundary, "Missing `#{spex_path}` with `use Boundary`")
    test_err = Context.error(ctx, test_path, :has_use_boundary, "Missing `#{test_path}` with `use Boundary`")

    case {spex_err, test_err} do
      {nil, nil} -> :valid
      {nil, msg} -> {:invalid, msg}
      {msg, nil} -> {:invalid, msg}
      {msg1, _msg2} -> {:invalid, "Missing both `#{spex_path}` and `#{test_path}` with `use Boundary` (e.g. #{msg1})"}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(scope, _task) do
    app_name = Helpers.app_name(scope)
    mod = Macro.camelize(app_name)

    {:ok, """
    # Configure Test Boundaries

    Create `test/support/#{app_name}_spex.ex`:
    ```elixir
    defmodule #{mod}Spex do
      use Boundary, top_level?: true, deps: [#{mod}, #{mod}Web]
    end
    ```

    Create `test/support/#{app_name}_test_boundary.ex`:
    ```elixir
    defmodule #{mod}Test do
      use Boundary, top_level?: true, deps: [#{mod}]
    end
    ```

    Note `#{mod}Spex` does NOT depend on `#{mod}Test`. Spex drive the app
    the way a user does — over HTTP or LiveView — and own their own sandbox
    setup; reaching into test support would couple the two boundaries for
    no gain. Add a dedicated fixtures boundary if spex need shared setup.

    Both root modules also need boundary declarations, or every module in
    the project compiles with a "not included in any boundary" warning:

    ```elixir
    # lib/#{app_name}.ex
    use Boundary, top_level?: true, deps: [], exports: :all

    # lib/#{app_name}_web.ex
    use Boundary, top_level?: true, deps: [#{mod}], exports: :all
    ```
    """}
  end
end
