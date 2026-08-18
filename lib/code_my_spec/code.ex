defmodule CodeMySpec.Code do
  @moduledoc """
  Reading Elixir source as data — what a file depends on, what it defines, what
  it asserts.

  One implementation sits behind this: `ElixirAst`, which parses a file (or a
  string of source) to an AST and walks it. Everything here delegates to it.

  Called by `StaticAnalysis` — never call `ElixirAst` directly. That is the same
  arrangement `StaticAnalysis` itself states about `Pipeline`, and it is what
  every other namespace in this tree does. `SpecAlignment` reaches past this
  module today and should stop when it next changes.

  Both shapes of every extractor are exposed. A path is what an analyzer has
  when it is walking a project; a string is what it has when the content came
  from somewhere other than disk, which is why the `*_from_source/1` variants
  exist at all — collapsing them would put a `File.write` in front of every
  in-memory call.
  """

  alias CodeMySpec.Code.ElixirAst

  @doc "Modules a file depends on, from its `alias`, `import` and `use` statements."
  defdelegate get_dependencies(file_path), to: ElixirAst

  @doc "Public functions a file defines, with their specs."
  defdelegate get_public_functions(file_path), to: ElixirAst

  @doc "Public functions defined in a string of source."
  defdelegate public_functions_from_source(content), to: ElixirAst

  @doc "Assertions a test file makes."
  defdelegate get_test_assertions(file_path), to: ElixirAst

  @doc "Assertions made in a string of test source."
  defdelegate test_assertions_from_source(content), to: ElixirAst
end
