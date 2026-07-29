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

  defdelegate compile(scope), to: Pipeline
  defdelegate compile(scope, opts), to: Pipeline
  defdelegate resolve_analyzers(task, changed_files, config), to: Pipeline
  defdelegate task_excluded_analyzers(task), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files, config), to: Pipeline
  defdelegate run_analyzers(scope, analyzers, changed_files, config, opts), to: Pipeline
  @doc """
  Resolve the environment an analyzer should shell out into.

  Analyzers already resolve their working directory as `opts[:cwd] ||
  scope.cwd`; this is the same precedence for the thing that actually runs the
  command. They are a public API callable without `StaticAnalysis.Runner`, so
  the resolution has to live where the analyzer can reach it rather than in
  the runner that usually calls it.

  The `:local` fallback is not a default standing in for a missing value.
  `System.cmd(cd: cwd)` — what these analyzers did before — *is* a local
  environment; naming it changes nothing about where the command runs. Scopes
  built server-side carry no environment because nothing there shells out.
  """
  @spec resolve_environment(keyword(), CodeMySpec.Users.Scope.t(), String.t()) ::
          CodeMySpec.Environments.Environment.t()
  def resolve_environment(opts, scope, cwd) do
    opts[:environment] || scope.environment ||
      CodeMySpec.Environments.Environment.new(:local, cwd)
  end
end
