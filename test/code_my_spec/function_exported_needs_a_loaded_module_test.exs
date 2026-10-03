defmodule CodeMySpec.FunctionExportedNeedsALoadedModuleTest do
  @moduledoc """
  `function_exported?/3` answers false for a module that is not loaded yet, and
  in interactive mode (dev, test) a module nothing has used since boot is not.
  A check written as `function_exported?(module, :evaluate, 3)` therefore picks
  the fallback branch on a cold module and the right one on a warm one.

  Found 2026-10-02 at six sites: `evaluate_task` dispatched a held
  `bdd_specs_passing` task to its read-only `evaluate/2` and answered "not
  certified" without certifying; the same shape sat in the evaluator's
  `before_evaluate`, the pipeline's analyzer lookups and two `init_session`
  checks. Each now loads the module first.

  This keeps the shape from coming back: a `function_exported?` on a module held
  in a variable needs `Code.ensure_loaded`/`ensure_loaded?` on the same line or
  just above it. A literal module (`__MODULE__`, `Foo.Bar`) is loaded by naming
  it and is exempt.
  """
  use ExUnit.Case, async: true

  @window 3

  test "every function_exported? on a variable module loads it first" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> String.split("\n"),
          {line, index} <- Enum.with_index(lines),
          variable_module_check?(line),
          not loaded_nearby?(lines, index),
          do: "#{path}:#{index + 1}: #{String.trim(line)}"

    assert offenders == [],
           "function_exported?/3 on a module that may not be loaded yet — call " <>
             "Code.ensure_loaded/1 first:\n" <> Enum.join(offenders, "\n")
  end

  # `function_exported?(module, ...)` where the first argument is a lowercase
  # variable, not a module literal. Comments are ignored.
  defp variable_module_check?(line) do
    not String.starts_with?(String.trim_leading(line), "#") and
      Regex.match?(~r/function_exported\?\(\s*[a-z_][a-zA-Z0-9_]*\s*,/, line)
  end

  defp loaded_nearby?(lines, index) do
    lines
    |> Enum.slice(max(index - @window, 0)..index)
    |> Enum.any?(&String.contains?(&1, "ensure_loaded"))
  end
end
