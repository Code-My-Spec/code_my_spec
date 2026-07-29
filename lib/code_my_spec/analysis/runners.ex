defmodule CodeMySpec.Analysis.Runners do
  @moduledoc """
  Thin adapters over the existing analyzer executors.

  Each runner shells out (via the underlying context module), converts tool
  output to `%Problem{}` structs, and returns a uniform result map:

      %{problems: [Problem.t()], output: String.t(), exit_status: integer() | nil, stats: map()}

  No persistence here — the Reconciler owns all writes. `opts` carries the
  cassette escape hatches (`:output_file`) so spex can drive runs from
  pre-recorded tool output.

  This is the device half of analysis: it needs a shell and the working copy,
  and nothing else. Problems come back unstamped — `Reconciler.stamp_project/2`
  sets `project_id` on every problem it persists, and `stamp_component_ids/3`
  resolves components through the Files table, which is a database join this
  side has no business doing. Runners used to set `project_id` too; the value
  was overwritten on the way in every time.
  """

  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Compile
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis.Runner, as: StaticRunner
  alias CodeMySpec.Tests
  alias CodeMySpec.Users.Scope

  @output_cap 100_000

  @type result :: %{
          problems: [struct()],
          output: String.t(),
          exit_status: integer() | nil,
          stats: map()
        }

  @spec run(String.t(), Scope.t(), [String.t()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def run("compiler", %Scope{} = scope, _args, opts) do
    execute_opts = [environment: scope.environment] |> maybe_output_file(opts)
    result = Compile.execute(execute_opts)

    problems =
      result.data.compiler_results
      |> Enum.map(&ProblemConverter.from_compiler/1)

    {errors, warnings} = Enum.split_with(problems, &(&1.severity == :error))

    {:ok,
     %{
       problems: problems,
       output: cap(format_problem_lines(problems)),
       exit_status: result.exit_code,
       stats: %{"errors" => length(errors), "warnings" => length(warnings)}
     }}
  end

  # Credo scope follows the run kind: no args → project-wide sweep (full,
  # memoizable); path args → scoped `--files` run over the changed set
  # (partial — refreshes only those files' problems, mirrors the old
  # pipeline's per-turn scoping and its recorded cassettes).
  def run("credo", %Scope{} = scope, args, opts) do
    files = if args == [], do: nil, else: args
    runner_opts = [files: files] |> maybe_output_file(opts)

    case StaticRunner.run(scope, :credo, runner_opts) do
      {:ok, problems} ->
        {:ok,
         %{
           problems: problems,
           output: cap(format_problem_lines(problems)),
           exit_status: if(problems == [], do: 0, else: 1),
           stats: %{"issues" => length(problems)}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run("exunit", %Scope{} = scope, args, opts) do
    exec_opts = [environment: scope.environment] |> maybe_output_file(opts)

    case Tests.execute(args, exec_opts) do
      # `mix test` exited nonzero without reporting a single failure: bad args,
      # a compile error, missing deps. The suite never ran, so this result says
      # nothing about the code.
      #
      # Returning `{:ok, problems: []}` here was actively harmful. The
      # Reconciler clears a source's Problems wholesale before inserting, so an
      # empty result wiped every real exunit Problem and then finished the run
      # `:completed` at the current fingerprint — and `tests_passing` checks
      # exactly those two things (a fresh completed run, zero problems). A
      # `mix test` that failed to start therefore reported the component's
      # tests as passing.
      #
      # Failing the run leaves it `:failed`: never fresh, never
      # problem-clearing, and re-enqueued on the next stop.
      {:ok, %{execution_status: :error} = test_run} ->
        {:error, {:test_suite_did_not_run, test_run.exit_code, error_excerpt(test_run.raw_output)}}

      {:ok, test_run} ->
        problems =
          test_run.failures
          |> Enum.map(&ProblemConverter.from_test_failure(&1.error))
          |> Enum.map(&%{&1 | source: "exunit"})

        {:ok,
         %{
           problems: problems,
           output: cap(test_run.raw_output || ""),
           exit_status: test_run.exit_code,
           stats: stats_map(test_run.stats)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run("spex", %Scope{} = scope, args, opts) do
    exec_opts = [environment: scope.environment] |> maybe_output_file(opts)

    case Spex.execute(args, exec_opts) do
      # The same trap as exunit above. `Spex.parse_jsonl/1` answers `{:ok, []}`
      # for a missing file, so "the run never happened" and "everything is
      # clean" are indistinguishable by the failure list alone — the nonzero
      # exit is the only thing separating them. Fail the run rather than let an
      # empty result clear every spex Problem and finish `:completed`.
      {:ok, [], exit_code} when exit_code != 0 ->
        {:error, {:spex_suite_did_not_run, exit_code}}

      {:ok, failures, exit_code} ->
        problems =
          failures
          |> Enum.map(&spex_failure_to_problem/1)
          |> Enum.map(&%{&1 | source: "spex"})

        {:ok,
         %{
           problems: problems,
           output: cap(format_problem_lines(problems)),
           exit_status: exit_code,
           stats: %{"failures" => length(failures)}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spex_failure_to_problem(failure) do
    ProblemConverter.from_test_failure(%{
      file: failure.error && failure.error.file,
      line: failure.error && failure.error.line,
      test: "#{failure.spex} — #{failure.scenario}",
      message: (failure.error && failure.error.message) || "Spex scenario failed"
    })
  end

  defp maybe_output_file(exec_opts, opts) do
    case Keyword.get(opts, :output_file) do
      nil -> exec_opts
      path -> Keyword.put(exec_opts, :output_file, path)
    end
  end

  defp stats_map(nil), do: %{}

  defp stats_map(stats) when is_struct(stats),
    do: stats |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end)

  defp stats_map(stats) when is_map(stats), do: stats

  defp format_problem_lines([]), do: "clean"

  defp format_problem_lines(problems) do
    Enum.map_join(problems, "\n", fn p ->
      "#{p.file_path}:#{p.line || "?"} [#{p.severity}] #{first_line(p.message)}"
    end)
  end

  defp first_line(nil), do: ""
  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  # mix reports *why* it wouldn't run at the very end of its output ("Paths
  # given to mix test did not match...", a compile error summary), so the tail
  # carries the signal and the head is compile chatter. Kept short: this rides
  # into the run's `stats["error"]`, which Reconciler.fail truncates at 500.
  defp error_excerpt(nil), do: ""

  defp error_excerpt(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(-3)
    |> Enum.join(" | ")
    |> String.slice(0, 300)
  end

  defp cap(output) when byte_size(output) > @output_cap,
    do: binary_part(output, 0, @output_cap) <> "\n… (truncated)"

  defp cap(output), do: output
end
