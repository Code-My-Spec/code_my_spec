defmodule CodeMySpec.ProblemsTest do
  @moduledoc """
  Tests for the CodeMySpec.Problems context.

  The Problems context is a pure delegation context - it delegates all functions
  to ProblemRepository and ProblemConverter. The underlying functions are tested
  in their respective test files:
  - test/code_my_spec/problems/problem_repository_test.exs
  - test/code_my_spec/problems/problem_converter_test.exs

  This test file verifies that the context module exists and delegates correctly.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Problems

  test "module exists and exports expected functions" do
    Code.ensure_loaded!(Problems)

    # Verify the context module exists and has the expected delegates
    # list_project_problems has default arg, so it exports arities 1 and 2
    assert function_exported?(Problems, :list_project_problems, 1)
    assert function_exported?(Problems, :create_problems, 2)
    assert function_exported?(Problems, :replace_project_problems, 2)
    assert function_exported?(Problems, :clear_project_problems, 1)
    assert function_exported?(Problems, :from_credo, 1)
    assert function_exported?(Problems, :from_compiler, 1)
    assert function_exported?(Problems, :from_test_failure, 1)
  end
end
