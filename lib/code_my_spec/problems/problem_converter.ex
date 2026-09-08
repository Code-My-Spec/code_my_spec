defmodule CodeMySpec.Problems.ProblemConverter do
  @moduledoc """
  Utility module for transforming heterogeneous tool outputs (Credo,
  compiler warnings, test failures) into normalized Problem structs. Provides
  consistent data transformation regardless of source tool format.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Utils.MapAccess

  @doc """
  Transforms Credo analysis results into normalized Problem structs.

  Extracts severity from Credo priority/category, maps check name to category,
  and builds a normalized Problem struct with Credo-specific metadata.

  ## Examples

      iex> credo_data = %{
      ...>   priority: 10,
      ...>   category: :readability,
      ...>   check: "Credo.Check.Readability.ModuleDoc",
      ...>   message: "Modules should have a @moduledoc tag.",
      ...>   filename: "lib/my_app/some_module.ex",
      ...>   line_no: 1
      ...> }
      iex> problem = ProblemConverter.from_credo(credo_data)
      iex> problem.severity
      :error
  """
  @spec from_credo(map()) :: Problem.t()
  def from_credo(credo_data) do
    %Problem{
      severity: map_credo_severity(field(credo_data, :priority)),
      source: "credo",
      source_type: :static_analysis,
      file_path: field(credo_data, :filename),
      line: field(credo_data, :line_no),
      message: field(credo_data, :message),
      category: map_credo_category(field(credo_data, :category)),
      rule: field(credo_data, :check),
      metadata: %{
        "check" => field(credo_data, :check),
        "priority" => field(credo_data, :priority),
        "category" => field(credo_data, :category),
        "column" => field(credo_data, :column),
        "trigger" => field(credo_data, :trigger),
        "scope" => field(credo_data, :scope)
      }
    }
  end

  # Credo's JSON output gives string keys; the doctest example uses atom keys.
  # `field/2` looks up either form.
  defp field(data, key) when is_atom(key), do: MapAccess.get(data, key)

  @doc """
  Transforms compiler warnings/errors into normalized Problem structs.

  Maps compiler severity (warning/error) to Problem severity and categorizes
  based on warning type (unused variables, undefined functions, etc.).

  ## Examples

      iex> compiler_data = %{
      ...>   severity: :warning,
      ...>   file: "lib/my_app/service.ex",
      ...>   line: 34,
      ...>   message: "variable \\"result\\" is unused"
      ...> }
      iex> problem = ProblemConverter.from_compiler(compiler_data)
      iex> problem.severity
      :warning
  """
  @spec from_compiler(map()) :: Problem.t()
  def from_compiler(compiler_data) do
    message = field(compiler_data, :message)

    %Problem{
      severity: map_compiler_severity(field(compiler_data, :severity)),
      source: "compiler",
      source_type: :static_analysis,
      file_path: field(compiler_data, :file),
      line: field(compiler_data, :line),
      message: message,
      category: categorize_compiler_message(message),
      rule: nil,
      metadata: %{}
    }
  end

  @doc """
  Transforms ExUnit test failure into normalized Problem struct.

  All test failures are mapped to :error severity and categorized as
  test_failure. Preserves the full test failure message including assertion
  details.

  ## Examples

      iex> test_error = %{
      ...>   file: "test/my_app/user_test.exs",
      ...>   line: 45,
      ...>   test: "test user creation",
      ...>   message: "Assertion failed"
      ...> }
      iex> problem = ProblemConverter.from_test_failure(test_error)
      iex> problem.severity
      :error
  """
  @spec from_test_failure(CodeMySpec.Tests.TestError.t() | map()) :: Problem.t()
  def from_test_failure(%CodeMySpec.Tests.TestError{} = test_error) do
    %Problem{
      severity: :error,
      source: "exunit",
      source_type: :test,
      file_path: test_error.file,
      line: test_error.line,
      message: test_error.message,
      category: "test_failure",
      rule: nil,
      metadata: %{
        "full_message" => test_error.message
      }
    }
  end

  def from_test_failure(test_error) when is_map(test_error) do
    test_name = field(test_error, :test)
    error_message = field(test_error, :message)

    message =
      case test_name do
        nil -> error_message
        name -> "#{name}: #{error_message}"
      end

    %Problem{
      severity: :error,
      source: "exunit",
      source_type: :test,
      file_path: field(test_error, :file),
      line: field(test_error, :line),
      message: message,
      category: "test_failure",
      rule: nil,
      metadata: %{
        "full_message" => error_message,
        "test" => test_name,
        "stacktrace" => field(test_error, :stacktrace)
      }
    }
  end

  # Private helper functions

  defp map_credo_severity(priority) when priority >= 10, do: :error
  defp map_credo_severity(priority) when priority >= 5, do: :warning
  defp map_credo_severity(_priority), do: :info

  defp map_credo_category(category) when is_atom(category), do: Atom.to_string(category)
  defp map_credo_category(category), do: category

  defp map_compiler_severity(:error), do: :error
  defp map_compiler_severity(:warning), do: :warning
  defp map_compiler_severity("error"), do: :error
  defp map_compiler_severity("warning"), do: :warning
  defp map_compiler_severity(_), do: :warning

  defp categorize_compiler_message(message) do
    cond do
      String.contains?(message, "variable") and String.contains?(message, "unused") ->
        "unused_variable"

      String.contains?(message, "undefined") and
          (String.contains?(message, "function") or String.contains?(message, "private")) ->
        "undefined_function"

      true ->
        "warning"
    end
  end
end
