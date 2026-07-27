defmodule CodeMySpec.Analysis.Runners do
  @moduledoc """
  Thin adapters over the existing analyzer executors.

  Each runner shells out (via the underlying context module), converts tool
  output to `%Problem{}` structs, and returns a uniform result map:

      %{problems: [Problem.t()], output: String.t(), exit_status: integer() | nil, stats: map()}

  No persistence here — the Reconciler owns all writes. `opts` carries the
  cassette escape hatches (`:output_file`) so spex can drive runs from
  pre-recorded tool output.
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
  def run("compiler", %Scope{cwd: cwd} = scope, _args, opts) do
    execute_opts = [cwd: cwd] |> maybe_output_file(opts)
    result = Compile.execute(execute_opts)

    problems =
      result.data.compiler_results
      |> Enum.map(&ProblemConverter.from_compiler/1)
      |> Enum.map(&%{&1 | project_id: scope.active_project_id})

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

  def run("exunit", %Scope{cwd: cwd} = scope, args, opts) do
    exec_opts = [project_root: cwd] |> maybe_output_file(opts)

    case Tests.execute(args, exec_opts) do
      {:ok, test_run} ->
        problems =
          test_run.failures
          |> Enum.map(&ProblemConverter.from_test_failure(&1.error))
          |> Enum.map(&%{&1 | project_id: scope.active_project_id, source: "exunit"})

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

  def run("spex", %Scope{cwd: cwd} = scope, args, opts) do
    exec_opts = [project_root: cwd] |> maybe_output_file(opts)

    case Spex.execute(args, exec_opts) do
      {:ok, failures, exit_code} ->
        problems =
          failures
          |> Enum.map(&spex_failure_to_problem/1)
          |> Enum.map(&%{&1 | project_id: scope.active_project_id, source: "spex"})

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

  defp cap(output) when byte_size(output) > @output_cap,
    do: binary_part(output, 0, @output_cap) <> "\n… (truncated)"

  defp cap(output), do: output
end
