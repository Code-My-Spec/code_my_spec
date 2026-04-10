defmodule CodeMySpec.StaticAnalysis do
  @moduledoc """
  Executes optional code quality and correctness tools against a project codebase.

  Provides a unified interface for running Credo (style/consistency),
  Boundary (module dependency enforcement), Sobelow (security), and custom static analyzers.
  Each tool writes output to temporary JSON files for reliable parsing, then normalizes results
  into Problems for consistent reporting and tracking.

  Separate from compilation and testing, which remain distinct concepts.
  """

  alias CodeMySpec.StaticAnalysis.{Pipeline, Runner}

  defdelegate list_analyzers(), to: Runner
  defdelegate run(scope, analyzer_name, opts \\ []), to: Runner
  defdelegate run_all(scope, opts \\ []), to: Runner

  defdelegate run_pipeline(scope, task, opts \\ []), to: Pipeline
end
