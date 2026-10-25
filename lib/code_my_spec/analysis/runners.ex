defmodule CodeMySpec.Analysis.Runners do
  @moduledoc """
  Thin adapters over the existing analyzer executors.

  Each runner shells out (via the underlying context module), converts tool
  output to `%Problem{}` structs, and returns a uniform result map:

      %{problems: [Problem.t()], output: String.t(), exit_status: integer() | nil, stats: map()}

  No persistence here — the Reconciler owns all writes. `opts` carries the
  cassette escape hatches (`:output_file`) so spex can drive runs from
  pre-recorded tool output.

  Problems come back unstamped: the Reconciler sets `project_id` and resolves
  `component_id` when it persists them.

  `run/4` executes locally; `from_raw/2` converts what an analyzer printed
  (a harness `analysis_result`) without executing anything. `run/4` goes
  through `from_raw/2` too, so both paths read a diagnostic identically.

  The raw shape is per source and is the wire contract with `CmsHarness.Analysis`:

      compiler  %{"exit_status" => int, "diagnostics" => [%{"file", "line", "severity", "message"}]}
      credo     %{"exit_status" => int, "diagnostics" => [credo issue json]}
      exunit    %{"exit_status" => int, "execution_status" => "success"|"failure"|"error",
                  "output" => raw stdout, "stats" => map, "partition" => string,
                  "diagnostics" => [%{"file", "line", "message"}]}
      spex      %{"exit_status" => int, "partition" => string,
                  "diagnostics" => [%{"spex", "scenario", "file", "line", "message"}]}

  `partition` is which test database the suite opened (exunit and spex only).
  It lands in the run's `stats`, not on each problem; an older harness omits it.
  """

  alias CodeMySpec.Analysis.LocalRunLink
  alias CodeMySpec.Analysis.RunNode
  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Compile
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.StaticAnalysis.Analyzers
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
  def run(source, %Scope{} = scope, args, opts) do
    cwd = opts[:cwd] || scope.cwd
    environment = StaticAnalysis.resolve_execution_context(opts, scope, cwd)

    if is_nil(environment) do
      {:error, :no_environment}
    else
      cwd = opts[:cwd] || environment.cwd
      environment = %{environment | cwd: cwd}
      opts = opts |> Keyword.put(:execution_context, environment) |> Keyword.put(:cwd, cwd)
      run_resolved(source, scope, args, opts)
    end
  end

  defp run_resolved("compiler", %Scope{} = _scope, _args, opts) do
    execute_opts =
      [execution_context: opts[:execution_context], cwd: opts[:cwd]] |> maybe_output_file(opts)

    result = Compile.execute(execute_opts)

    from_raw("compiler", %{
      "exit_status" => result.exit_code,
      "diagnostics" => result.data.compiler_results,
      "diagnostics_available" => Map.get(result.data, :diagnostics_available, true),
      "output" => result.output
    })
  end

  # No args → project-wide sweep (full); path args → `--files` run over the
  # changed set (partial: refreshes only those files' problems).
  # Calls `Analyzers.Credo` directly because `StaticRunner.run/3` has no raw
  # output channel; that also skips its availability check, hence `available?/2`.
  defp run_resolved("credo", %Scope{} = scope, args, opts) do
    files = if args == [], do: nil, else: args

    runner_opts =
      opts
      |> Keyword.put(:files, files)
      |> Keyword.put(:extra_env, RunNode.credo_env(LocalRunLink.env(scope, opts[:run_id])))
      |> maybe_output_file(opts)

    if Analyzers.Credo.available?(scope, runner_opts) do
      case Analyzers.Credo.run_with_output(scope, runner_opts) do
        {:ok, problems, output} ->
          {:ok,
           summarize(
             problems,
             if(problems == [], do: 0, else: 1),
             %{"issues" => length(problems)},
             output
           )}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Analyzer credo is not available"}
    end
  end

  # Always a full sweep: sobelow takes no `--files` option.
  defp run_resolved("sobelow", %Scope{} = scope, _args, opts) do
    runner_opts = maybe_output_file(opts, opts)

    if Analyzers.Sobelow.available?(scope, runner_opts) do
      case Analyzers.Sobelow.run_with_output(scope, runner_opts) do
        {:ok, problems, output} ->
          {:ok,
           summarize(
             problems,
             if(problems == [], do: 0, else: 1),
             %{"issues" => length(problems)},
             output
           )}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Analyzer sobelow is not available"}
    end
  end

  defp run_resolved("exunit", %Scope{} = scope, args, opts) do
    exec_opts =
      [
        execution_context: opts[:execution_context],
        cwd: opts[:cwd],
        extra_env: LocalRunLink.env(scope, opts[:run_id])
      ]
      |> maybe_output_file(opts)

    case Tests.execute(args, exec_opts) do
      {:ok, test_run} ->
        from_raw("exunit", %{
          "exit_status" => test_run.exit_code,
          "execution_status" => to_string(test_run.execution_status),
          "output" => test_run.raw_output || "",
          "stats" => stats_map(test_run.stats),
          "diagnostics" =>
            Enum.map(test_run.failures || [], fn failure ->
              %{
                "file" => failure.error && failure.error.file,
                "line" => failure.error && failure.error.line,
                "message" => (failure.error && failure.error.message) || failure.full_title
              }
            end)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_resolved("spex", %Scope{} = _scope, args, opts) do
    exec_opts =
      [execution_context: opts[:execution_context], cwd: opts[:cwd]] |> maybe_output_file(opts)

    case Spex.execute(args, exec_opts) do
      {:ok, failures, exit_code, output} ->
        from_raw("spex", %{
          "exit_status" => exit_code,
          "output" => cap(output),
          "diagnostics" =>
            Enum.map(failures, fn failure ->
              {file, line} = spex_location(failure.error, failure.spec_file)

              %{
                "spex" => failure.spex,
                "scenario" => failure.scenario,
                "file" => file,
                "line" => line,
                "message" => failure.error && failure.error.message
              }
            end)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Convert what an analyzer printed into a runner result, without running
  anything. A harness's `analysis_result` comes in through here.
  """
  @spec from_raw(String.t(), map()) :: {:ok, result()} | {:error, term()}
  def from_raw("compiler", raw) do
    problems = raw |> diagnostics() |> Enum.map(&ProblemConverter.from_compiler/1)
    {errors, warnings} = Enum.split_with(problems, &(&1.severity == :error))

    # A build that failed and said nothing is not a clean build: fail the run
    # (re-enqueued, never a Problem). Keyed on `diagnostics_available`, not exit
    # status — `--return-errors` exits 0 on a compile error.
    # See knowledge/analysis, "A run that saw nothing is not clean".
    if raw["diagnostics_available"] == false do
      {:error, {:compile_diagnostics_unavailable, raw["exit_status"]}}
    else
      {:ok,
       summarize(
         problems,
         raw["exit_status"],
         %{"errors" => length(errors), "warnings" => length(warnings)},
         raw["output"]
       )}
    end
  end

  def from_raw("credo", raw) do
    problems = raw |> diagnostics() |> Enum.map(&ProblemConverter.from_credo/1)

    {:ok, summarize(problems, raw["exit_status"], %{"issues" => length(problems)}, raw["output"])}
  end

  # The suite never ran (bad args, compile error, missing deps). An empty `:ok`
  # would clear every exunit Problem and read as passing tests; a failed run is
  # never fresh and is re-enqueued.
  # See knowledge/analysis, "A run that saw nothing is not clean".
  def from_raw("exunit", %{"execution_status" => "error"} = raw) do
    {:error, {:test_suite_did_not_run, raw["exit_status"], error_excerpt(raw["output"])}}
  end

  # Zero tests is not zero failures: the same trap reached through a zero exit.
  # Only the exact `%{"tests" => 0}` shape matches; a payload with no stats
  # falls through rather than being failed on a guess.
  def from_raw("exunit", %{"execution_status" => status, "stats" => %{"tests" => 0}} = raw)
      when is_binary(status) do
    {:error, {:test_suite_did_not_run, raw["exit_status"], error_excerpt(raw["output"])}}
  end

  # Whatever the analyzer reports is recorded; no diagnostic is dropped or
  # second-guessed.
  # See knowledge/analysis, "Never drop diagnostics".
  def from_raw("exunit", %{"execution_status" => status} = raw) when is_binary(status) do
    exunit_result(raw)
  end

  # `Spex.parse_jsonl/1` answers `{:ok, []}` for a missing file, so a nonzero
  # exit with no failures is a suite that never ran: fail the run, carrying an
  # output excerpt so the reason is recorded somewhere.
  def from_raw("spex", raw) do
    exit_code = raw["exit_status"]

    case {diagnostics(raw), exit_code} do
      {[], code} when code != 0 ->
        {:error, {:spex_suite_did_not_run, code, error_excerpt(raw["output"])}}

      {failures, code} ->
        {:ok, with_partition(spex_result(failures, code, raw["output"]), raw)}
    end
  end

  # An exunit payload with no `execution_status`, or an unknown source, is
  # refused: read charitably it would become a clean `:completed` run.
  def from_raw(source, _raw), do: {:error, {:unreadable_result, source}}

  defp spex_result(failures, exit_code, output) do
    problems =
      failures
      |> Enum.map(&%{spex_failure_to_problem(&1) | source: "spex"})

    summarize(problems, exit_code, %{"failures" => length(failures)}, output)
  end

  # Required, not defaulted: a missing key defaulted to `[]` would report the
  # source clean. It raises.
  defp diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics), do: diagnostics

  defp diagnostics(raw) do
    raise ArgumentError,
          "analysis result carries no diagnostics list; refusing to read it as a clean run: " <>
            inspect(Map.keys(raw))
  end

  defp exunit_result(raw) do
    problems =
      raw
      |> diagnostics()
      |> Enum.map(fn failure ->
        %{
          ProblemConverter.from_test_failure(%CodeMySpec.Tests.TestError{
            file: failure["file"],
            line: failure["line"],
            message: failure["message"]
          })
          | source: "exunit"
        }
      end)

    {:ok,
     with_partition(
       %{
         problems: problems,
         output: cap(raw["output"] || ""),
         exit_status: raw["exit_status"],
         stats: raw["stats"] || %{}
       },
       raw
     )}
  end

  # Which test database answered, once per run. Absent for compiler and credo
  # (no connection) and from an older harness.
  # See knowledge/analysis, "Runner results".
  defp with_partition(summary, %{"partition" => partition})
       when is_binary(partition) and partition != "" do
    %{summary | stats: Map.put(summary.stats, "partition", partition)}
  end

  defp with_partition(summary, _raw), do: summary

  # `output` is the tool's own text, not a summary of `problems`
  # (`.code_my_spec/rules/analysis_output_fidelity.md`). The
  # `format_problem_lines/1` fallback is only for an older harness that sends
  # no `"output"`.
  defp summarize(problems, exit_status, stats, output) do
    %{
      problems: problems,
      output: cap(output || format_problem_lines(problems)),
      exit_status: exit_status,
      stats: stats
    }
  end

  defp spex_failure_to_problem(failure) do
    ProblemConverter.from_test_failure(%{
      file: failure["file"],
      line: failure["line"],
      test: "#{failure["spex"]} — #{failure["scenario"]}",
      message: failure["message"] || "Spex scenario failed"
    })
  end

  # A spex failure belongs to its spec or to no file, never to the library
  # frame that raised. File and line come from the same frame.
  # See knowledge/analysis, "Spex failure location".
  @doc false
  # Public so the rule can be asserted without a live `mix spex`.
  def spex_location(error, spec_file \\ nil)

  def spex_location(nil, _spec_file), do: {nil, nil}

  def spex_location(error, spec_file) do
    case spec_frame(error.stacktrace) do
      # No spec frame (raise from setup, a fixture, a plug): never fall back to
      # a non-spec `error.file`.
      nil -> spec_file_fallback(error, spec_file)
      frame -> {frame_get(frame, "file"), frame_get(frame, "line")}
    end
  end

  # `error.file` when it is itself a spec (the formatter's backstop failures set
  # it to the spex's own file), and the declared spec otherwise.
  defp spec_file_fallback(error, spec_file) do
    file = error_get(error, :file)

    if is_binary(file) and String.ends_with?(file, "_spex.exs") do
      {file, error_get(error, :line)}
    else
      declared_spec(spec_file)
    end
  end

  # Last resort, for a raise on another process's stack (e.g. a LiveView), where
  # no frame names the spec. Line is deliberately `nil`: where in the spec is
  # unknown.
  defp declared_spec(spec_file) when is_binary(spec_file) do
    if String.ends_with?(spec_file, "_spex.exs"), do: {spec_file, nil}, else: {nil, nil}
  end

  defp declared_spec(_spec_file), do: {nil, nil}

  defp error_get(error, key) when is_map(error),
    do: Map.get(error, key) || Map.get(error, Atom.to_string(key))

  defp error_get(_error, _key), do: nil

  defp spec_frame(stacktrace) when is_list(stacktrace) do
    Enum.find(stacktrace, fn frame ->
      file = frame_get(frame, "file")
      is_binary(file) and String.ends_with?(file, "_spex.exs")
    end)
  end

  defp spec_frame(_stacktrace), do: nil

  defp frame_get(frame, key) when is_map(frame),
    do: Map.get(frame, key) || Map.get(frame, String.to_existing_atom(key))

  defp frame_get(_frame, _key), do: nil

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

  # Kept short: rides into the run's `stats["error"]`, which `Reconciler.fail`
  # truncates at 500.
  defp error_excerpt(nil), do: ""

  # Without an ExUnit summary: the last line-opening `** (` marker, else the
  # output tail. The last three lines of a mix crash are boilerplate, and the
  # first marker is often a mid-suite Postgrex log line.
  # See knowledge/analysis, "Runner results".
  defp error_excerpt(output) do
    lines = output |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.split("\n")

    case Enum.find(Enum.reverse(lines), &Regex.match?(~r/^\s*\d+ tests?, \d+ failures?\b/, &1)) do
      nil -> exception_excerpt(output, lines)
      summary -> suite_excerpt(summary, lines)
    end
  end

  # Process crashes logged deliberately by tests are not the suite's verdict.
  # Prefer ExUnit's summary, followed by its first numbered failure and location.
  defp suite_excerpt(summary, lines) do
    failure =
      lines
      |> Enum.drop_while(&(not Regex.match?(~r/^\s*1\) /, &1)))
      |> Enum.take(2)

    [summary | failure]
    |> Enum.map_join(" | ", &String.trim/1)
    |> String.slice(0, 300)
  end

  defp exception_excerpt(output, lines) do
    case Enum.filter(lines, &String.starts_with?(String.trim_leading(&1), "** (")) do
      [] -> tail_excerpt(output)
      markers -> markers |> List.last() |> String.trim() |> String.slice(0, 300)
    end
  end

  defp tail_excerpt(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(-3)
    |> Enum.join(" | ")
    |> String.slice(0, 300)
  end

  # On a character boundary: a split multibyte char makes Postgres refuse the
  # row, and a green run is recorded as one that could not run.
  @doc "Retain the start and failure tail of analyzer output within 100KB, including markers."
  @spec cap(binary()) :: String.t()
  def cap(output) do
    output = String.replace_invalid(output)

    if byte_size(output) > @output_cap do
      gap = "\n… (middle omitted) …\n"
      marker = "\n… (truncated)"
      head = output |> binary_part(0, 20_000) |> drop_partial_char()
      tail_size = @output_cap - byte_size(head) - byte_size(gap) - byte_size(marker)

      tail =
        output
        |> binary_part(byte_size(output) - tail_size, tail_size)
        |> drop_leading_partial_char()

      head <> gap <> tail <> marker
    else
      output
    end
  end

  defp drop_leading_partial_char(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_leading_partial_char(rest)

  defp drop_leading_partial_char(binary), do: binary

  # The input is already valid, so only a trailing partial sequence can fail.
  defp drop_partial_char(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(0, byte_size(binary) - 1) |> drop_partial_char()
  end
end
