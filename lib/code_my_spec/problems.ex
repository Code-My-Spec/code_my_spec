defmodule CodeMySpec.Problems do
  @moduledoc """
  A unified abstraction for problems, warnings, and errors discovered across
  different analysis tools and validation processes. Normalizes heterogeneous
  tool outputs into a consistent data model that can be used both ephemerally
  (in-memory during sessions) and persistently (stored for project-level fitness tracking).
  """

  alias CodeMySpec.Problems.{ProblemConverter, ProblemRenderer, ProblemRepository}

  # Repository functions
  defdelegate list_project_problems(scope, opts \\ []), to: ProblemRepository
  defdelegate watermark(scope), to: ProblemRepository
  defdelegate list_problems_paginated(scope, opts \\ []), to: ProblemRepository
  defdelegate create_problems(scope, problems), to: ProblemRepository
  defdelegate replace_project_problems(scope, problems), to: ProblemRepository
  defdelegate replace_problems_for_files(scope, file_paths, problems), to: ProblemRepository
  defdelegate clear_project_problems(scope), to: ProblemRepository

  defdelegate replace_problems_for_components(scope, component_ids, source, problems),
    to: ProblemRepository

  defdelegate delete_problems_for_components(scope, component_ids), to: ProblemRepository
  defdelegate clear_problems_for_source(scope, source_filter, file_paths), to: ProblemRepository

  defdelegate reconcile_problems_for_source(scope, source, file_scope, problems),
    to: ProblemRepository

  defdelegate clear_problems_for_missing_files(scope, current_paths), to: ProblemRepository
  defdelegate component_ids_with_problems(scope), to: ProblemRepository

  # Converter functions
  defdelegate from_credo(credo_data), to: ProblemConverter
  defdelegate from_compiler(compiler_data), to: ProblemConverter
  defdelegate from_test_failure(test_error), to: ProblemConverter

  # Renderer functions
  defdelegate render_stop_response(blocking, advisory, opts \\ []), to: ProblemRenderer
  defdelegate advisory_assignment_note(advisory, assignment), to: ProblemRenderer
  defdelegate truncate_to_cap(text, opts \\ []), to: ProblemRenderer
end
