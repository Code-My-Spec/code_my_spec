defmodule CodeMySpec.StaticAnalysis.Runner do
  @moduledoc """
  Orchestrates execution of static analyzers against a project. Handles parallel execution,
  error isolation, and result aggregation.

  The Runner provides a unified interface for running static analysis tools (Credo,
  Sobelow) either individually or in parallel. It manages analyzer
  availability checks, error handling, and ensures all returned Problems have proper project_id
  assignments.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.StaticAnalysis.Analyzers.{Credo, Sobelow}
  alias CodeMySpec.Users.Scope

  require Logger

  @doc """
  Get list of all registered static analyzer modules.

  Returns a hardcoded list of analyzer modules in consistent execution order.

  ## Examples

      iex> Runner.list_analyzers()
      [
        CodeMySpec.StaticAnalysis.Analyzers.Credo,
        CodeMySpec.StaticAnalysis.Analyzers.Sobelow
      ]
  """
  @spec list_analyzers() :: [module()]
  def list_analyzers do
    [
      Credo,
      Sobelow
    ]
  end

  @doc """
  Execute a specific static analyzer against a project.

  Resolves the analyzer module from an atom name (e.g., :credo -> Credo), checks if it's
  available, executes it, and validates all returned Problems have project_id set.

  ## Parameters

  - `scope` - The scope containing active account and project context
  - `analyzer_name` - Atom identifying the analyzer (e.g., :credo, :sobelow)
  - `opts` - Keyword list of options passed through to the analyzer

  ## Returns

  - `{:ok, [Problem.t()]}` - List of problems found during analysis
  - `{:error, :no_environment}` - No runtime is available for this request
  - `{:error, String.t()}` - Error message if execution fails

  ## Examples

      iex> Runner.run(scope, :credo)
      {:ok, [%Problem{}, ...]}

      iex> Runner.run(scope, :sobelow, paths: ["lib"])
      {:ok, [%Problem{}, ...]}

      iex> Runner.run(scope, :nonexistent)
      {:error, "Unknown analyzer: nonexistent"}
  """
  @spec run(Scope.t(), atom(), keyword()) ::
          {:ok, [Problem.t()]} | {:error, String.t() | :no_environment}
  def run(%Scope{} = scope, analyzer_name, opts \\ []) do
    environment = resolve_execution_context(scope, opts)
    opts = opts |> Keyword.put(:execution_context, environment) |> put_runtime_cwd(environment)

    with {:ok, _project} <- validate_project(scope),
         :ok <- validate_cwd(environment, opts),
         {:ok, analyzer_module} <- resolve_analyzer(analyzer_name),
         {:ok, :available} <- check_availability(analyzer_module, scope, opts),
         {:ok, problems} <- execute_analyzer(analyzer_module, scope, opts) do
      validate_problems(problems, scope)
    end
  end

  @doc """
  Execute all available static analyzers against a project in parallel.

  Runs all registered analyzers concurrently using Task.async_stream, aggregates results,
  and logs warnings for any analyzers that fail or timeout. Provides error isolation so that
  failures in one analyzer don't prevent others from executing.

  ## Parameters

  - `scope` - The scope containing active account and project context
  - `opts` - Keyword list of options:
    - `:timeout` - Timeout in milliseconds for each analyzer task (default: 120_000)

  ## Returns

  - `{:ok, [Problem.t()]}` - Aggregated list of problems from all successful analyzers
  - `{:error, :no_environment}` - No runtime is available for this request
  - `{:error, String.t()}` - The runtime has no working directory

  ## Examples

      iex> Runner.run_all(scope)
      {:ok, [%Problem{}, ...]}

      iex> Runner.run_all(scope, timeout: 60_000)
      {:ok, [%Problem{}, ...]}
  """
  @spec run_all(Scope.t(), keyword()) ::
          {:ok, [Problem.t()]} | {:error, String.t() | :no_environment}
  def run_all(%Scope{} = scope, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    environment = resolve_execution_context(scope, opts)
    opts = opts |> Keyword.put(:execution_context, environment) |> put_runtime_cwd(environment)

    with :ok <- validate_cwd(environment, opts) do
      problems =
        list_analyzers()
        |> filter_available_analyzers(scope, opts)
        |> execute_analyzers_parallel(scope, opts, timeout)
        |> aggregate_results(scope)

      {:ok, problems}
    end
  end

  # Private functions

  defp validate_project(%Scope{active_project: nil}),
    do: {:error, "No project in scope"}

  defp validate_project(%Scope{active_project: project}),
    do: {:ok, project}

  defp validate_cwd(nil, _opts), do: {:error, :no_environment}

  defp validate_cwd(environment, opts) do
    case Keyword.get(opts, :cwd) || environment.cwd do
      cwd when is_binary(cwd) and cwd != "" -> :ok
      _ -> {:error, "No working directory (cwd) in scope"}
    end
  end

  defp resolve_execution_context(scope, opts) do
    StaticAnalysis.resolve_execution_context(opts, scope, Keyword.get(opts, :cwd) || scope.cwd)
  end

  defp put_runtime_cwd(opts, %{cwd: cwd}) when is_binary(cwd) and cwd != "",
    do: Keyword.put_new(opts, :cwd, cwd)

  defp put_runtime_cwd(opts, _environment), do: opts

  defp resolve_analyzer(analyzer_name) when is_atom(analyzer_name) do
    analyzer_map = %{
      credo: Credo,
      sobelow: Sobelow
    }

    case Map.get(analyzer_map, analyzer_name) do
      nil -> {:error, "Unknown analyzer: #{analyzer_name}"}
      module -> {:ok, module}
    end
  end

  defp check_availability(analyzer_module, scope, opts) do
    if analyzer_module.available?(scope, opts),
      do: {:ok, :available},
      else: {:error, "Analyzer #{analyzer_module.name()} is not available"}
  rescue
    exception ->
      Logger.error("Error checking analyzer availability: #{inspect(exception)}")
      {:error, "Failed to check analyzer availability: #{Exception.message(exception)}"}
  end

  defp execute_analyzer(analyzer_module, scope, opts) do
    case analyzer_module.run(scope, opts) do
      {:ok, problems} when is_list(problems) ->
        {:ok, problems}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "Unexpected analyzer result: #{inspect(other)}"}
    end
  rescue
    exception ->
      Logger.error("Analyzer #{analyzer_module.name()} crashed: #{inspect(exception)}")
      {:error, "Analyzer execution failed: #{Exception.message(exception)}"}
  end

  defp validate_problems(problems, %Scope{active_project_id: project_id})
       when is_list(problems) do
    # Ensure all problems have project_id set
    validated =
      Enum.map(problems, fn problem ->
        if is_nil(problem.project_id) do
          Map.put(problem, :project_id, project_id)
        else
          problem
        end
      end)

    {:ok, validated}
  end

  defp filter_available_analyzers(analyzers, scope, opts) do
    Enum.filter(analyzers, fn analyzer ->
      try do
        analyzer.available?(scope, opts)
      rescue
        exception ->
          Logger.error(
            "Error checking availability of analyzer #{inspect(analyzer)}: #{inspect(exception)}"
          )

          false
      end
    end)
  end

  defp execute_analyzers_parallel(analyzers, scope, opts, timeout) do
    Task.async_stream(
      analyzers,
      fn analyzer ->
        try do
          case analyzer.run(scope, opts) do
            {:ok, problems} ->
              {:ok, analyzer.name(), problems}

            {:error, reason} ->
              {:error, analyzer.name(), reason}
          end
        rescue
          exception ->
            {:error, analyzer.name(), Exception.message(exception)}
        end
      end,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp aggregate_results(stream_results, %Scope{active_project_id: project_id}) do
    stream_results
    |> Enum.flat_map(fn
      {:ok, {:ok, analyzer_name, problems}} ->
        Logger.debug("Analyzer #{analyzer_name} completed with #{length(problems)} problems")
        Enum.map(problems, &ensure_project_id(&1, project_id))

      {:ok, {:error, analyzer_name, reason}} ->
        Logger.warning("Analyzer #{analyzer_name} failed: #{inspect(reason)}")
        []

      {:exit, :timeout} ->
        Logger.warning("Analyzer timed out")
        []

      {:exit, reason} ->
        Logger.warning("Analyzer exited: #{inspect(reason)}")
        []

      other ->
        Logger.warning("Unexpected analyzer result: #{inspect(other)}")
        []
    end)
  end

  # Handle case when scope doesn't have active_project_id (shouldn't happen but be defensive)
  defp aggregate_results(stream_results, _scope) do
    stream_results
    |> Enum.flat_map(fn
      {:ok, {:ok, analyzer_name, problems}} ->
        Logger.debug("Analyzer #{analyzer_name} completed with #{length(problems)} problems")
        problems

      {:ok, {:error, analyzer_name, reason}} ->
        Logger.warning("Analyzer #{analyzer_name} failed: #{inspect(reason)}")
        []

      {:exit, :timeout} ->
        Logger.warning("Analyzer timed out")
        []

      {:exit, reason} ->
        Logger.warning("Analyzer exited: #{inspect(reason)}")
        []

      other ->
        Logger.warning("Unexpected analyzer result: #{inspect(other)}")
        []
    end)
  end

  defp ensure_project_id(%{project_id: nil} = problem, project_id) do
    Map.put(problem, :project_id, project_id)
  end

  defp ensure_project_id(problem, _project_id), do: problem
end
