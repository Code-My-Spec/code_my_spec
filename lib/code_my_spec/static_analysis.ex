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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Compile,
      CodeMySpec.Documents,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Paths,
      CodeMySpec.Problems,
      CodeMySpec.TempFile,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.StaticAnalysis.{Pipeline, Runner}

  defdelegate list_analyzers(), to: Runner
  defdelegate run(scope, analyzer_name, opts \\ []), to: Runner
  defdelegate run_all(scope, opts \\ []), to: Runner

  defdelegate compile(scope), to: Pipeline
  defdelegate compile(scope, opts), to: Pipeline
  defdelegate resolve_analyzers(task, changed_files, config), to: Pipeline
  defdelegate task_excluded_analyzers(task), to: Pipeline
  defdelegate task_analyzers(task), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files, config), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files, config, opts), to: Pipeline

  @doc """
  Resolve the execution environment. An explicitly supplied `:environment`
  wins, including `nil`. Otherwise a selected working copy is authoritative,
  including when it cannot be resolved. `cwd` is the legacy local-runner
  directory supplied by the caller; this function never uses process cwd.
  """
  @spec resolve_environment(keyword(), CodeMySpec.Users.Scope.t(), String.t() | nil) ::
          CodeMySpec.Environments.Environment.t() | nil
  def resolve_environment(opts, scope, cwd) do
    case Keyword.fetch(opts, :environment) do
      {:ok, environment} ->
        environment

      :error ->
        resolve_unset_environment(scope, cwd)
    end
  end

  defp resolve_unset_environment(%{active_working_copy_id: id} = scope, _cwd) when not is_nil(id),
    do: CodeMySpec.WorkingCopies.environment(scope)

  defp resolve_unset_environment(_scope, cwd) when is_binary(cwd) and cwd != "",
    do: Environment.new(:local, cwd)

  defp resolve_unset_environment(_scope, _cwd), do: nil
end
