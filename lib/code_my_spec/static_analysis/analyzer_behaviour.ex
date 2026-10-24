defmodule CodeMySpec.StaticAnalysis.AnalyzerBehaviour do
  @moduledoc """
  Behaviour defining the interface that all static analyzers must implement.

  Specifies callbacks for running analysis and checking availability. Each analyzer
  implements these callbacks to execute its specific tool (Credo, Boundary,
  Sobelow, or custom analyzers) and normalize results into Problem structs for
  consistent reporting.

  This behaviour enables pluggable static analysis with uniform error handling and
  result aggregation.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Users.Scope

  @doc """
  Execute the static analysis tool against a project and return normalized Problems.

  Implementations should invoke their specific tool, parse the output, and transform
  results into Problem structs using ProblemConverter or custom logic.

  ## Parameters

  - `scope` - The scope containing active account and project context
  - `opts` - Keyword list of options (e.g., config_file, paths, timeout)

  ## Returns

  - `{:ok, [Problem.t()]}` - List of problems found during analysis
  - `{:error, String.t()}` - Error message if execution fails
  """
  @callback run(scope :: Scope.t(), opts :: keyword()) ::
              {:ok, [Problem.t()]} | {:error, String.t() | :no_environment}

  @doc """
  Check if the analyzer's tool is available and can be executed.

  Implementations should verify that the required executable or Mix task exists
  and is properly configured.

  ## Parameters

  - `scope` - The scope containing project context
  - `opts` - Runtime options shared with execution, including `:execution_context`

  ## Returns

  - `true` if the tool can be executed
  - `false` otherwise
  """
  @callback available?(scope :: Scope.t(), opts :: keyword()) :: boolean()

  @doc """
  Return the human-readable name of the analyzer for reporting and logging purposes.

  ## Returns

  A string identifying the analyzer (e.g., "Credo", "Boundary", "Sobelow")
  """
  @callback name() :: String.t()
end
