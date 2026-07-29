defmodule CodeMySpec.StaticAnalysis.Runner do
  @moduledoc """
  Orchestrates execution of static analyzers against a project. Handles parallel execution,
  error isolation, and result aggregation.

  The Runner provides a unified interface for running static analysis tools (Credo,
  Sobelow, SpecAlignment) either individually or in parallel. It manages analyzer
  availability checks, error handling, and ensures all returned Problems have proper project_id
  assignments.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.StaticAnalysis.Analyzers.{Credo, Sobelow, SpecAlignment}
  alias CodeMySpec.Users.Scope

  require Logger

  @doc """
  Get list of all registered static analyzer modules.

  Returns a hardcoded list of analyzer modules in consistent execution order.

  ## Examples

      iex> Runner.list_analyzers()
      [
        CodeMySpec.StaticAnalysis.Analyzers.Credo,
        CodeMySpec.StaticAnalysis.Analyzers.Sobelow,
        CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
      ]
  """
  @spec list_analyzers() :: [module()]
  def list_analyzers do
    [
      Credo,
      Sobelow,
      SpecAlignment
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
  - `{:error, String.t()}` - Error message if execution fails

  ## Examples

      iex> Runner.run(scope, :credo)
      {:ok, [%Problem{}, ...]}

      iex> Runner.run(scope, :spec_alignment, paths: ["lib"])
      {:ok, [%Problem{}, ...]}

      iex> Runner.run(scope, :nonexistent)
      {:error, "Unknown analyzer: nonexistent"}
  """
  @spec run(Scope.t(), atom(), keyword()) :: {:ok, [Problem.t()]} | {:error, String.t()}
  def run(%Scope{} = scope, analyzer_name, opts \\ []) do
    with {:ok, _project} <- validate_project(scope),
         :ok <- validate_cwd(scope),
         {:ok, analyzer_module} <- resolve_analyzer(analyzer_name),
         {:ok, :available} <- check_availability(analyzer_module, scope),
         opts_with_cwd = ensure_cwd_option(opts, scope),
         {:ok, problems} <- execute_analyzer(analyzer_module, scope, opts_with_cwd) do
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
  - `{:error, String.t()}` - Error only if project validation fails

  ## Examples

      iex> Runner.run_all(scope)
      {:ok, [%Problem{}, ...]}

      iex> Runner.run_all(scope, timeout: 60_000)
      {:ok, [%Problem{}, ...]}
  """
  @spec run_all(Scope.t(), keyword()) :: {:ok, [Problem.t()]} | {:error, String.t()}
  def run_all(%Scope{} = scope, opts \\ []) do
    # Don't validate project early - let filter_available_analyzers handle it
    # If no cwd is set, no analyzers will be available and we'll return empty list
    timeout = Keyword.get(opts, :timeout, 120_000)

    opts_with_cwd =
      case scope.cwd do
        cwd when is_binary(cwd) and cwd != "" ->
          Keyword.put_new(opts, :cwd, cwd)

        _ ->
          opts
      end

    problems =
      list_analyzers()
      |> filter_available_analyzers(scope)
      |> execute_analyzers_parallel(scope, opts_with_cwd, timeout)
      |> aggregate_results(scope)

    {:ok, problems}
  end

  # Private functions

  defp validate_project(%Scope{active_project: nil}),
    do: {:error, "No project in scope"}

  defp validate_project(%Scope{active_project: project}),
    do: {:ok, project}

  defp validate_cwd(%Scope{cwd: cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp validate_cwd(_scope), do: {:error, "No working directory (cwd) in scope"}

  defp ensure_cwd_option(opts, %Scope{cwd: cwd}) when is_binary(cwd) do
    Keyword.put_new(opts, :cwd, cwd)
  end

  defp ensure_cwd_option(opts, _scope), do: opts


  defp resolve_analyzer(analyzer_name) when is_atom(analyzer_name) do
    analyzer_map = %{
      credo: Credo,
      sobelow: Sobelow,
      spec_alignment: SpecAlignment
    }

    case Map.get(analyzer_map, analyzer_name) do
      nil -> {:error, "Unknown analyzer: #{analyzer_name}"}
      module -> {:ok, module}
    end
  end

  defp check_availability(analyzer_module, scope) do
    case analyzer_module.available?(scope) do
      true -> {:ok, :available}
      false -> {:error, "Analyzer #{analyzer_module.name()} is not available"}
    end
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

  defp filter_available_analyzers(analyzers, scope) do
    Enum.filter(analyzers, fn analyzer ->
      try do
        analyzer.available?(scope)
      rescue
        _ -> false
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
