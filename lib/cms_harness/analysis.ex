defmodule CmsHarness.Analysis do
  @moduledoc """
  Run one analyzer against the working copy and say what it printed.

  This is the half of analysis that cannot live on the server: it needs the
  bytes on this disk and a toolchain to run against them. The other half —
  turning tool output into `Problem` rows, deciding whether they block, and
  recording that a run happened — is database work and stays there.

  So nothing here knows what a Problem is. It runs `mix`, reads the JSON the
  tool wrote, and hands back the diagnostics unchanged. The server converts
  them with the same `ProblemConverter` it has always used, which is what keeps
  a harness-run analyzer and a server-run analyzer producing identical rows.

  The executors themselves are `cms_scan`'s copies of `CodeMySpec.Compile`,
  `CodeMySpec.Tests` and `CodeMySpec.BddSpecs.Spex` — byte-identical to the
  server's and pinned by `cms_scan`'s drift test — plus
  `StaticAnalysis.CredoRun`, which is the shell-out half of the server's Credo
  analyzer.

  ## The wire shape

  `run/3` answers `{:ok, result}` where result is the map the server's
  `Analysis.Runners.from_raw/2` reads:

      %{
        "source" => "compiler" | "credo" | "exunit" | "spex",
        "exit_status" => integer() | nil,
        "diagnostics" => [map()],       # raw, source-specific
        "output" => String.t() | nil,   # raw stdout; exunit only
        "stats" => map() | nil          # exunit only
      }

  and `{:error, reason}` when the tool did not run. Those two are kept apart on
  purpose and all the way down: an analyzer that failed to start prints no
  diagnostics, and an analyzer that ran clean prints no diagnostics, and the
  entire point of this project is that those must not arrive at the server as
  the same answer.
  """

  require Logger

  alias CmsHarness.AnalyzerEnv
  alias CodeMySpec.Analysis.Runners
  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Compile
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.StaticAnalysis.CredoRun

  @output_cap 100_000

  @sources ~w(compiler credo exunit spex)

  @doc "The analyzer sources this harness knows how to run."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  Run `source` against `project`'s working copy.

  `args` are the analyzer's own arguments — empty for the stop hook's
  whole-project sweep, paths for a targeted run.
  """
  @spec run(map(), String.t(), [String.t()]) :: {:ok, map()} | {:error, String.t()}
  def run(project, source, args \\ []) when is_binary(source) and is_list(args) do
    env = Environment.new(:local, project.root)
    started = System.monotonic_time(:millisecond)

    result = execute(source, env, args)

    Logger.info(
      "[CmsHarness] #{source} #{inspect(args)} in #{project.root} took " <>
        "#{System.monotonic_time(:millisecond) - started}ms"
    )

    result
  end

  defp execute("compiler", env, _args) do
    result = Compile.execute(environment: env, extra_env: AnalyzerEnv.extra_env(env))

    {:ok,
     %{
       "source" => "compiler",
       "exit_status" => result.exit_code,
       "diagnostics" => Enum.map(result.data.compiler_results, &stringify/1),
       # Whether anything was recording. `mix compile --return-errors` exits 0
       # even on a compile error, so the exit status cannot tell the server
       # "clean" from "nobody looked" — only this can.
       "diagnostics_available" => Map.get(result.data, :diagnostics_available, true)
     }}
  rescue
    exception -> crashed("compiler", exception)
  end

  defp execute("credo", env, args) do
    files = if args == [], do: nil, else: args

    case CredoRun.run(env, files: files, extra_env: AnalyzerEnv.extra_env(env)) do
      {:ok, issues} ->
        {:ok,
         %{
           "source" => "credo",
           # Credo's own exit code is not carried: the server derives one from
           # the issue count exactly as `Runners.run/4` does locally, so the
           # two paths record the same number.
           "exit_status" => if(issues == [], do: 0, else: 1),
           "diagnostics" => issues
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  rescue
    exception -> crashed("credo", exception)
  end

  defp execute("exunit", env, args) do
    case CodeMySpec.Tests.execute(args, environment: env, extra_env: AnalyzerEnv.extra_env(env)) do
      {:ok, test_run} ->
        {:ok,
         %{
           "source" => "exunit",
           "exit_status" => test_run.exit_code,
           # The server needs this to tell "the suite ran and failed" from
           # "the suite never started". It refuses to reconcile the second,
           # because an empty failure list from a `mix test` that never ran
           # would clear every real exunit Problem and then report the suite
           # fresh and passing. That defect is on record; this field is what
           # stops it happening over a wire as well.
           "execution_status" => to_string(test_run.execution_status),
           "output" => cap(test_run.raw_output || ""),
           "stats" => stats_map(test_run.stats),
           "diagnostics" => Enum.map(test_run.failures || [], &test_failure/1)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    exception -> crashed("exunit", exception)
  end

  defp execute("spex", env, args) do
    case Spex.execute(args, environment: env, extra_env: AnalyzerEnv.extra_env(env)) do
      {:ok, failures, exit_code} ->
        {:ok,
         %{
           "source" => "spex",
           "exit_status" => exit_code,
           "diagnostics" => Enum.map(failures, &spex_failure/1)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    exception -> crashed("spex", exception)
  end

  defp execute(source, _env, _args), do: {:error, "unknown analyzer source: #{source}"}

  defp crashed(source, exception) do
    Logger.error("[CmsHarness] #{source} crashed: #{Exception.message(exception)}")
    {:error, "#{source} crashed: #{Exception.message(exception)}"}
  end

  # `%TestResult{error: %TestError{}}` reduced to the three fields the server's
  # converter reads. It rebuilds the struct on the far side so a failure
  # reported by a harness and one reported locally produce the same Problem,
  # metadata included.
  defp test_failure(%{error: nil} = failure) do
    %{"file" => nil, "line" => nil, "message" => failure.full_title || failure.title}
  end

  defp test_failure(%{error: error}) do
    %{"file" => error.file, "line" => error.line, "message" => error.message}
  end

  # Through the shared rule rather than a second copy of it.
  #
  # There were two: this one, and `CodeMySpec.Analysis.Runners.run/4` for a
  # server that has the disk itself. Fixing the location bug in that one changed
  # nothing here, because a light harness never executes it — the same finding
  # came back filed against `lib/req_cassette/plug.ex` on the next run, from a
  # harness that had been restarted specifically to pick the fix up.
  #
  # `Runners.spex_location/1` is the one place that decides it now. CmsHarness
  # may depend on CodeMySpec, so this needs no third home.
  defp spex_failure(failure) do
    {file, line} = Runners.spex_location(failure.error)

    %{
      "spex" => failure.spex,
      "scenario" => failure.scenario,
      "file" => file,
      "line" => line,
      "message" => failure.error && failure.error.message
    }
  end

  # Compiler diagnostics come off the JSONL with string keys already; the
  # recovered-from-stdout fallback builds them the same way. This only guards
  # against an atom-keyed map reaching JSON encoding as something the server
  # then reads with the wrong key.
  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stats_map(nil), do: nil

  defp stats_map(stats) when is_struct(stats),
    do: stats |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), serialize(v)} end)

  defp stats_map(stats) when is_map(stats), do: stats

  defp serialize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp serialize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize(value), do: value

  defp cap(output) when byte_size(output) > @output_cap,
    do: binary_part(output, 0, @output_cap) <> "\n… (truncated)"

  defp cap(output), do: output
end
