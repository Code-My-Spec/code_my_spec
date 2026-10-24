defmodule CodeMySpec.ExecutionContexts.AProjectRecipeRunsItsSuiteTest do
  @moduledoc """
  How a project runs its own suites is the project's to say. A justfile that
  declares `spex` or `test` is what the runners call, with the arguments they
  would have given `mix`; without one, `mix` as before.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.Tests

  defmodule FakeShell do
    @moduledoc false
    def cmd(env, "just", ["--list"], _opts),
      do: {"Available recipes:\n    " <> Enum.join(env.metadata.recipes, "\n    ") <> "\n", 0}

    def cmd(env, command, args, _opts) do
      send(env.metadata.test, {:ran, command, args})
      {"", 0}
    end
  end

  defp a_project(recipes) do
    env = no_justfile(recipes)
    :ok = ExecutionContexts.write_file(env, "justfile", "# recipes\n")
    ExecutionContexts.cmd(env, "chmod", ["+x", "justfile"])
    env
  end

  defp no_justfile(recipes) do
    {:ok, env} =
      InMemoryExecutionContext.create(
        shell_module: FakeShell,
        metadata: %{test: self(), recipes: recipes}
      )

    env
  end

  describe "recipe?/2" do
    test "names a recipe the justfile lists" do
      assert ExecutionContexts.recipe?(a_project(["spex *args", "test-file file"]), "spex")
    end

    test "does not take a longer name for it" do
      refute ExecutionContexts.recipe?(a_project(["test-file file"]), "test"),
             "`test-file` is not `test`; the gate would run a recipe that takes one file"
    end

    test "is false with no justfile" do
      refute ExecutionContexts.recipe?(no_justfile(["spex *args"]), "spex")
    end
  end

  test "spex runs the project's recipe with the arguments it gives mix" do
    env = a_project(["spex *args"])

    Spex.execute(["test/spex/a_spex.exs"], execution_context: env)

    assert_received {:ran, "just", ["spex", "test/spex/a_spex.exs", "--jsonl=" <> _]}
  end

  test "spex runs mix when the project declares no recipe" do
    env = a_project(["serve"])

    Spex.execute(["test/spex/a_spex.exs"], execution_context: env)

    # `mix spex` itself is answered by the in-memory environment's replay, not
    # the shell, so what is observable is that `just` was not run.
    refute_received {:ran, "just", _}
  end

  test "exunit runs the project's test recipe with the arguments it gives mix" do
    env = a_project(["test *args"])

    Tests.execute(["test/a_test.exs"], execution_context: env)

    assert_received {:ran, "just", ["test", "--formatter", "ClientUtils.TestFormatter" | rest]}
    assert "test/a_test.exs" in rest
  end
end
