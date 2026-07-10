defmodule CodeMySpec.Analysis.Execution do
  @moduledoc """
  Executes one analysis run synchronously: runner → reconcile.

  This is the function the ProjectServer's supervised Task runs, kept
  standalone so tests can drive a run to completion without GenServer or
  sandbox-ownership gymnastics.
  """

  require Logger

  alias CodeMySpec.Analysis.{Reconciler, Run, Runners}
  alias CodeMySpec.Problems
  alias CodeMySpec.Users.Scope

  @doc """
  Run `run`'s analyzer and reconcile the results.

  Every non-compiler run is skipped (marked `:failed`) while blocking
  compiler errors are persisted — analyzers and test suites against code
  that doesn't compile waste the queue and emit garbage. A skipped run is
  `:failed`, never `:completed`, so it re-enqueues once the compile is fixed.

  Returns `{:ok, run}` (finished row) or `{:error, reason}`.
  """
  @spec execute(Scope.t(), Run.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def execute(%Scope{} = scope, %Run{} = run, opts \\ []) do
    if skip_for_compile_errors?(scope, run) do
      Reconciler.fail(run, :skipped_compile_errors)
    else
      run_and_reconcile(scope, run, opts)
    end
  end

  defp run_and_reconcile(scope, run, opts) do
    start = System.monotonic_time(:millisecond)
    args = run_args(run)

    case Runners.run(run.source, scope, args, runner_opts(run, opts)) do
      {:ok, result} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.info("[Analysis] #{run.source} #{inspect(args)} finished in #{ms}ms")
        Reconciler.reconcile(scope, run, result, opts)

      {:error, reason} ->
        Reconciler.fail(run, reason)
        {:error, reason}
    end
  end

  defp skip_for_compile_errors?(_scope, %Run{source: "compiler"}), do: false

  defp skip_for_compile_errors?(scope, _run) do
    scope
    |> Problems.list_project_problems(source: "compiler", severity: :error)
    |> Enum.any?()
  end

  defp run_args(%Run{args: %{"args" => args}}) when is_list(args), do: args
  defp run_args(%Run{args: args}) when is_list(args), do: args
  defp run_args(_run), do: []

  # Cassette escape hatch: spex inject pre-recorded tool output per source.
  defp runner_opts(%Run{source: source}, opts) do
    key = :"#{output_key(source)}_output_file"

    case Keyword.get(opts, key) do
      nil -> []
      path -> [output_file: path]
    end
  end

  defp output_key("compiler"), do: :compile
  defp output_key("exunit"), do: :exunit
  defp output_key(source), do: String.to_atom(source)
end
