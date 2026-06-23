defmodule CodeMySpec.CompileTest do
  @moduledoc """
  Tests for `CodeMySpec.Compile.extract_compiler_errors/1`, the fallback that
  decides whether a non-zero `mix compile` exit with no diagnostics file is a
  real code error or a transient/infrastructure failure.

  Regression: a config/mix.exs change forces a rebuild; the stop-hook compile
  exits non-zero before writing diagnostics; the old fallback fabricated a
  blocking "compiler error" from Mix's progress banner ("==> boundary"),
  masquerading as a code error and blocking the stop hook.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Compile

  describe "extract_compiler_errors/1" do
    test "returns [] for Mix dep-compilation banners (the phantom-error case)" do
      output = """
      ==> boundary
      Compiling 15 files (.ex)
      Generated boundary app
      ==> file_system
      Compiling 7 files (.ex)
      Generated file_system app
      """

      assert Compile.extract_compiler_errors(output) == []
    end

    test "returns [] for the 'must restart after changing configuration files' RuntimeError" do
      output = """
      ** (RuntimeError) could not compile application: code_my_spec.
      You must restart your server after changing configuration files or your dependencies.
      """

      assert Compile.extract_compiler_errors(output) == []
    end

    test "ignores dependency warnings (warnings are not errors)" do
      output = """
      ==> floki
      Compiling 30 files (.ex)
           warning: the variable "namespace_size" is accessed inside size(...)
           └─ lib/floki/selector.ex:111:33: Floki.Selector.namespace_match?/2
      Generated floki app
      """

      assert Compile.extract_compiler_errors(output) == []
    end

    test "recovers a genuine CompileError" do
      output = """
      ==> code_my_spec
      Compiling 1 file (.ex)

      == Compilation error in file lib/code_my_spec/foo.ex ==
      ** (CompileError) lib/code_my_spec/foo.ex:12: undefined function bar/0
      """

      errors = Compile.extract_compiler_errors(output)

      assert length(errors) == 2
      assert Enum.all?(errors, &(&1["severity"] == "error"))
      assert Enum.any?(errors, &String.contains?(&1["message"], "** (CompileError)"))
    end

    test "recovers a genuine error: diagnostic line" do
      output = """
      ==> code_my_spec
      Compiling 1 file (.ex)
          error: undefined variable "scope"
          └─ lib/code_my_spec/bar.ex:7:5: CodeMySpec.Bar.baz/1
      """

      errors = Compile.extract_compiler_errors(output)

      assert [%{"severity" => "error", "message" => "error: undefined variable \"scope\""}] = errors
    end

    test "a real error wins even alongside dep banners" do
      output = """
      ==> boundary
      Generated boundary app
      ==> code_my_spec
      ** (SyntaxError) lib/code_my_spec/baz.ex:3:1: syntax error before: end
      """

      assert [%{"message" => message}] = Compile.extract_compiler_errors(output)
      assert String.contains?(message, "** (SyntaxError)")
    end
  end
end
