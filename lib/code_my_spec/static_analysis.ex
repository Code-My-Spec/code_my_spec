defmodule CodeMySpec.StaticAnalysis do
  @moduledoc """
  Public API for compilation and static analysis.

  Provides a unified interface for:
  - Compilation with problem persistence
  - Analyzer resolution (role-derived + task-declared)
  - Running analyzers (Credo, spec validation, etc.)
  - Individual analyzer execution (Runner)

  Called by `Validation` context — never call `Pipeline` directly.
  """

  alias CodeMySpec.StaticAnalysis.{Pipeline, Runner}

  defdelegate list_analyzers(), to: Runner
  defdelegate run(scope, analyzer_name, opts \\ []), to: Runner
  defdelegate run_all(scope, opts \\ []), to: Runner

  defdelegate compile(scope, changed_file_paths), to: Pipeline
  defdelegate resolve_analyzers(task, changed_files, config \\ nil), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files), to: Pipeline
end
