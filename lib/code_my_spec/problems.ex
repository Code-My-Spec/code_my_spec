defmodule CodeMySpec.Problems do
  @moduledoc """
  The Problems context provides a unified abstraction for problems, warnings, and errors
  discovered across different analysis tools and validation processes. It normalizes
  heterogeneous tool outputs into a consistent data model that can be used both ephemerally
  (in-memory during sessions) and persistently (stored for project-level fitness tracking).
  """

  alias CodeMySpec.Problems.{ProblemConverter, ProblemRepository}

  # Repository functions
  defdelegate list_project_problems(scope, opts \\ []), to: ProblemRepository
  defdelegate create_problems(scope, problems), to: ProblemRepository
  defdelegate replace_project_problems(scope, problems), to: ProblemRepository
  defdelegate replace_problems_for_files(scope, file_paths, problems), to: ProblemRepository
  defdelegate clear_project_problems(scope), to: ProblemRepository
  defdelegate replace_problems_for_components(scope, component_ids, source, problems),
    to: ProblemRepository

  defdelegate delete_problems_for_components(scope, component_ids), to: ProblemRepository
  defdelegate clear_problems_for_source(scope, source_filter, file_paths), to: ProblemRepository
  defdelegate component_ids_with_problems(scope), to: ProblemRepository

  # Converter functions
  defdelegate from_credo(credo_data), to: ProblemConverter
  defdelegate from_compiler(compiler_data), to: ProblemConverter
  defdelegate from_test_failure(test_error), to: ProblemConverter
end
