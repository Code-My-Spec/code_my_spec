defmodule CodeMySpec.AgentTasks.Setup.TestSupportNamespace do
  @moduledoc """
  Setup step: ConnCase/DataCase use AppTest namespace.
  """

  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}

  @test_support_files ["conn_case.ex", "data_case.ex"]

  def check(%Context{} = ctx) do
    case Context.app_name(ctx) do
      nil -> {:invalid, "Could not determine app name from `mix.exs`"}
      app -> check_namespace(ctx, app)
    end
  end

  defp check_namespace(ctx, app) do
    test_ns = "#{Macro.camelize(app)}Test"

    wrong = Enum.reject(@test_support_files, &file_in_namespace?(ctx, &1, test_ns))

    if wrong == [],
      do: :valid,
      else: {:invalid, "#{Enum.join(wrong, ", ")} not in `#{test_ns}` namespace under `test/support/`"}
  end

  # Missing files are treated as OK (matches the original :enoent → true polarity).
  defp file_in_namespace?(ctx, file, test_ns) do
    path = Path.join(["test", "support", file])

    case Context.data(ctx, path, :module_name) do
      nil -> true
      module -> String.starts_with?(module, "#{test_ns}.")
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
    # Move Test Support to #{mod}Test Namespace

    Rename in `test/support/conn_case.ex`:
    `#{mod}Web.ConnCase` → `#{mod}Test.ConnCase`

    Rename in `test/support/data_case.ex`:
    `#{mod}.DataCase` → `#{mod}Test.DataCase`

    Update all test files that `use` these modules.

    Then create compatibility shims so Phoenix generators keep working —
    `mix phx.gen.auth` / `phx.gen.live` / `phx.gen.html` hardcode the default
    case-module names in every test they emit, and without these shims their
    output does not compile:

    `test/support/conn_case_compat.ex`:
    ```elixir
    defmodule #{mod}Web.ConnCase do
      @moduledoc \"\"\"
      Compatibility shim: Phoenix generators emit `use #{mod}Web.ConnCase`.
      The real case module is `#{mod}Test.ConnCase` — forward to it.
      \"\"\"
      defmacro __using__(opts) do
        quote do
          use #{mod}Test.ConnCase, unquote(opts)
        end
      end
    end
    ```

    `test/support/data_case_compat.ex`:
    ```elixir
    defmodule #{mod}.DataCase do
      @moduledoc \"\"\"
      Compatibility shim: Phoenix generators emit `use #{mod}.DataCase`.
      The real case module is `#{mod}Test.DataCase` — forward to it.
      \"\"\"
      defmacro __using__(opts) do
        quote do
          use #{mod}Test.DataCase, unquote(opts)
        end
      end
    end
    ```

    Newly generated tests then compile as-emitted; normalize them to the
    `#{mod}Test.*` names whenever you next touch those files.
    """}
  end
end
