defmodule CodeMySpec.Documents.Parsers.FunctionParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Documents.Function
  alias CodeMySpec.Documents.Parsers.FunctionParser

  describe "from_ast/1" do
    test "extracts function name from H3" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"p", [], ["Description here"], %{}}
      ]

      assert [%Function{name: "build/1"}] = FunctionParser.from_ast(ast)
    end

    test "extracts description from paragraph" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"p", [], ["Apply dependency tree processing."], %{}}
      ]

      assert [%Function{description: "Apply dependency tree processing."}] =
               FunctionParser.from_ast(ast)
    end

    test "extracts spec from elixir code block" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"pre", [],
         [
           {"code", [{"class", "elixir"}], ["@spec build([Component.t()]) :: [Component.t()]"],
            %{}}
         ], %{}}
      ]

      assert [%Function{spec: "@spec build([Component.t()]) :: [Component.t()]"}] =
               FunctionParser.from_ast(ast)
    end

    test "extracts process steps from **Process**: section" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"p", [], ["**Process**:"], %{}},
        {"ol", [],
         [
           {"li", [], ["Step 1"], %{}},
           {"li", [], ["Step 2"], %{}},
           {"li", [], ["Step 3"], %{}}
         ], %{}}
      ]

      assert [%Function{process: process}] = FunctionParser.from_ast(ast)
      assert process =~ "1. Step 1"
      assert process =~ "2. Step 2"
      assert process =~ "3. Step 3"
    end

    test "extracts test assertions list from **Test Assertions**: section" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"p", [], ["**Test Assertions**:"], %{}},
        {"ul", [],
         [
           {"li", [], ["build/1 returns empty list for empty input"], %{}},
           {"li", [], ["build/1 processes components in dependency order"], %{}}
         ], %{}}
      ]

      assert [%Function{test_assertions: assertions}] = FunctionParser.from_ast(ast)
      assert "build/1 returns empty list for empty input" in assertions
      assert "build/1 processes components in dependency order" in assertions
    end

    test "handles functions with missing optional fields" do
      ast = [
        {"h3", [], ["build/1"], %{}}
      ]

      assert [%Function{name: "build/1", description: nil, spec: nil, process: nil}] =
               FunctionParser.from_ast(ast)
    end

    test "handles multiple functions in single AST" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"p", [], ["First function"], %{}},
        {"h3", [], ["parse/2"], %{}},
        {"p", [], ["Second function"], %{}}
      ]

      functions = FunctionParser.from_ast(ast)
      assert length(functions) == 2
      assert Enum.any?(functions, &(&1.name == "build/1"))
      assert Enum.any?(functions, &(&1.name == "parse/2"))
    end

    test "returns empty list for empty AST" do
      assert [] = FunctionParser.from_ast([])
    end

    test "extracts complete function with all fields" do
      ast = [
        {"h3", [], ["build/1"], %{}},
        {"p", [], ["Apply dependency tree processing."], %{}},
        {"pre", [],
         [
           {"code", [{"class", "elixir"}], ["@spec build([Component.t()]) :: [Component.t()]"],
            %{}}
         ], %{}},
        {"p", [], ["**Process**:"], %{}},
        {"ol", [],
         [
           {"li", [], ["Sort components"], %{}},
           {"li", [], ["Build tree"], %{}}
         ], %{}},
        {"p", [], ["**Test Assertions**:"], %{}},
        {"ul", [],
         [
           {"li", [], ["build/1 returns empty list"], %{}},
           {"li", [], ["build/1 processes in order"], %{}}
         ], %{}}
      ]

      assert [%Function{} = func] = FunctionParser.from_ast(ast)
      assert func.name == "build/1"
      assert func.description == "Apply dependency tree processing."
      assert func.spec == "@spec build([Component.t()]) :: [Component.t()]"
      assert func.process =~ "1. Sort components"
      assert func.test_assertions == ["build/1 returns empty list", "build/1 processes in order"]
    end
  end
end
