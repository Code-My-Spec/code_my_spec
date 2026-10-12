defmodule CodeMySpec.Analysis.Execution do
  @moduledoc """
  Executes one analysis run synchronously: runner → reconcile.

  This is the function the ProjectServer's supervised Task runs, kept
  standalone so tests can drive a run to completion without GenServer or
  sandbox-ownership gymnastics.
  """

  require Logger

  alias CodeMySpec.Analysis.{Reconciler, Run, Runners}
  alias CodeMySpec.Environments
  alias CodeMySpec.Problems
  alias CodeMySpec.StaticAnalysis
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
    environment = resolve_environment(scope, opts)
    opts = Keyword.put(opts, :environment, environment)

    case Runners.run(run.source, scope, args, runner_opts(environment, run, opts)) do
      {:ok, %{problems: problems} = result} ->
        ms = System.monotonic_time(:millisecond) - start

        Logger.info(
          "[Analysis] run #{run.id} (#{run.source} #{inspect(args)}) finished in #{ms}ms"
        )

        if starved?(problems) do
          Logger.warning(
            "[Analysis] run #{run.id} (#{run.source}) skipped: every finding is an identical " <>
              "exit against #{starved_pid(problems)} — one shared process starving, not a " <>
              "verdict about the code (`5d798e1a`)"
          )

          Reconciler.fail(run, :resource_starved)
        else
          Reconciler.reconcile(scope, run, result, opts)
        end

      {:error, reason} ->
        Reconciler.fail(run, reason)
        {:error, reason}
    end
  end

  @doc """
  Every finding in this run is an identical exit against one shared pid.

  Public and separately tested, because it is a narrow, load-bearing claim
  rather than an implementation detail of `execute/3`. A run this true of has
  not produced a verdict about the code — it caught one process starving
  (Briefly's, or whatever else serializes through a single GenServer) and
  reported it once per test that happened to touch it. Deliberately narrow:
  `5d798e1a` tried and explicitly rejected wall-clock ratios and "an
  exception was raised" text as signals, because both can also match a run
  with genuine failures mixed in. This cannot — it requires every single
  finding to name the exact same pid, which a run with even one real
  assertion failure will not do.
  """
  @spec starved?([%{message: String.t() | nil}]) :: boolean()
  def starved?([]), do: false

  def starved?(problems) do
    problems
    |> Enum.map(&exited_pid/1)
    |> case do
      [pid | _] = pids -> pid != nil and Enum.all?(pids, &(&1 == pid))
      [] -> false
    end
  end

  defp starved_pid(problems), do: problems |> Enum.map(&exited_pid/1) |> hd()

  @exit_pid_pattern ~r/\*\* \(exit\) exited in: GenServer\.call\((#PID<[\d.]+>)/

  defp exited_pid(%{message: message}) when is_binary(message) do
    case Regex.run(@exit_pid_pattern, message) do
      [_, pid] -> pid
      _ -> nil
    end
  end

  defp exited_pid(_problem), do: nil

  @doc """
  Should this run be skipped because the project does not compile?

  Public because the light harness path asks the same question from
  `Analysis.dispatch_remote/3` — there the skip has to happen before the run is
  sent, since the machine that would answer it is not this one. Same rule,
  decided a step earlier.
  """
  @spec skip_for_compile_errors?(Scope.t(), Run.t()) :: boolean()
  def skip_for_compile_errors?(_scope, %Run{source: "compiler"}), do: false

  def skip_for_compile_errors?(scope, _run) do
    scope
    |> Problems.list_project_problems(source: "compiler", severity: :error)
    |> Enum.any?()
  end

  defp run_args(%Run{args: %{"args" => args}}) when is_list(args), do: args
  defp run_args(%Run{args: args}) when is_list(args), do: args
  defp run_args(_run), do: []

  defp resolve_environment(scope, opts) do
    cwd = opts[:cwd] || scope.cwd

    StaticAnalysis.resolve_environment(opts, scope, cwd)
  end

  # Cassette escape hatch: spex inject pre-recorded tool output per source,
  # per call or attached to the environment selected for this run.
  defp runner_opts(environment, %Run{source: source}, opts) do
    key = :"#{output_key(source)}_output_file"

    output_file = Keyword.get(opts, key) || Environments.recorded_output(environment, source)
    if output_file, do: Keyword.put(opts, :output_file, output_file), else: opts
  end

  defp output_key("compiler"), do: :compile
  defp output_key("exunit"), do: :exunit
  defp output_key(source), do: String.to_atom(source)
end
