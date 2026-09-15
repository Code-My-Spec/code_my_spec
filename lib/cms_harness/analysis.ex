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
        "output" => String.t() | nil,   # raw stdout, all four sources
        "stats" => map() | nil,         # exunit only
        "partition" => String.t()       # exunit and spex: which database answered
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
  whole-project sweep, paths for a targeted run. `run_id` is the server's
  ledger row for this execution when the caller has one (every real dispatch
  does — `AnalysisServer.run_with_slot/3` gets it off the queued `entry`);
  optional so direct/manual calls (and the existing test suite) still work
  without inventing one.
  """
  @spec run(map(), String.t(), [String.t()], integer() | nil) :: {:ok, map()} | {:error, String.t()}
  def run(project, source, args \\ [], run_id \\ nil)
      when is_binary(source) and is_list(args) do
    env = Environment.new(:local, project.root)
    started = System.monotonic_time(:millisecond)

    result = source |> execute(env, args) |> stamp_partition(env, source)

    Logger.info(
      "[CmsHarness] #{source} #{inspect(args)} in #{project.root}#{run_id_suffix(run_id)} " <>
        "took #{System.monotonic_time(:millisecond) - started}ms — #{describe_outcome(result)}"
    )

    result
  end

  defp run_id_suffix(nil), do: ""
  defp run_id_suffix(run_id), do: " (run #{run_id})"

  @doc """
  What a finished run found, for the line that says it finished.

  The line used to end at the duration, and the `\#{inspect(args)}` before it
  reads as a result when it is not — `exunit [] in <root> took 418381ms` says
  the run took no arguments and nothing whatever about what it found. A run
  that found twelve failures and a run that found none logged identically.

  That is not a cosmetic gap. Tracing a refused promotion on 2026-09-13 I read
  eight of these as "clean", concluded two checkouts were green, and spent four
  hours on the wrong theory while one of them carried a regression of mine.
  `harness.log` is the first place anybody looks and it was the one place that
  could not answer (`9afcbbdf`).

  Every source's result carries `"diagnostics"` and `"exit_status"`, so there is
  nothing to compute — only to say.
  """
  @spec describe_outcome({:ok, map()} | {:error, term()}) :: String.t()
  def describe_outcome({:ok, %{"diagnostics" => diagnostics} = result})
      when is_list(diagnostics) do
    "#{length(diagnostics)} finding(s), exit #{Map.get(result, "exit_status", "?")}"
  end

  # A source that reported no diagnostics key at all. Said plainly rather than
  # rendered as zero: "nothing found" and "nothing reported" are the distinction
  # `execution_status` exists for, and flattening them here would undo it.
  def describe_outcome({:ok, _result}), do: "no diagnostics reported"

  def describe_outcome({:error, reason}) do
    "failed: " <> (reason |> to_string() |> String.slice(0, 160))
  end

  # Which database the suite answered about, carried with the answer.
  #
  # A working copy has three test databases and a run uses exactly one, and
  # nothing said which. Measured twice: 479 spex failures naming a column the
  # tree had, against a partition five days behind the base (`d86b09cd`); and a
  # criterion passing in isolation while failing every sweep, because
  # `working_copies_device_id_fkey` was `CASCADE` on one database and `RESTRICT`
  # on the other. Both read as broken code and neither was. The second cost
  # three promotion refusals before anyone thought to ask which database had
  # answered (`9d4ae2de`).
  #
  # Only the two sources that open a connection. The compiler and credo read
  # files, so naming a partition on their findings would be a true fact about an
  # irrelevant thing — and a reader who takes it as relevant is worse off than
  # one who was told nothing.
  #
  # Safe to resolve here: every `execute/3` clause has already called
  # `extra_env/2` for this same environment by the time a result exists, so a
  # copy whose partition cannot be resolved has raised long before this runs.
  defp stamp_partition({:ok, result}, env, source) when source in ~w(exunit spex) do
    case List.keyfind(AnalyzerEnv.extra_env(env, source), "MIX_TEST_PARTITION", 0) do
      {_key, partition} -> {:ok, Map.put(result, "partition", partition)}
      nil -> {:ok, result}
    end
  end

  defp stamp_partition(result, _env, _source), do: result

  defp execute("compiler", env, _args) do
    result = Compile.execute(environment: env, extra_env: AnalyzerEnv.extra_env(env, "compiler"))

    {:ok,
     %{
       "source" => "compiler",
       "exit_status" => result.exit_code,
       "diagnostics" => Enum.map(result.data.compiler_results, &stringify/1),
       # Whether anything was recording. `mix compile --return-errors` exits 0
       # even on a compile error, so the exit status cannot tell the server
       # "clean" from "nobody looked" — only this can.
       "diagnostics_available" => Map.get(result.data, :diagnostics_available, true),
       # What the compiler actually printed, not a count reformatted from
       # `diagnostics`. See .code_my_spec/rules/analysis_output_fidelity.md.
       "output" => result.output
     }}
  rescue
    exception -> crashed("compiler", exception)
  end

  defp execute("credo", env, args) do
    files = if args == [], do: nil, else: args

    case CredoRun.run(env, files: files, extra_env: AnalyzerEnv.extra_env(env, "credo")) do
      {:ok, issues, output} ->
        {:ok,
         %{
           "source" => "credo",
           # Credo's own exit code is not carried: the server derives one from
           # the issue count exactly as `Runners.run/4` does locally, so the
           # two paths record the same number.
           "exit_status" => if(issues == [], do: 0, else: 1),
           "diagnostics" => issues,
           # What credo actually printed (JSON, per CredoRun's fixed output
           # flags) — not a count, not a line reformatted from `issues`. See
           # .code_my_spec/rules/analysis_output_fidelity.md.
           "output" => output
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  rescue
    exception -> crashed("credo", exception)
  end

  defp execute("exunit", env, args) do
    extra_env = AnalyzerEnv.extra_env(env, "exunit")

    # No pre-run truncate. There used to be one here, clearing rows that had
    # "escaped the ExUnit sandbox" — and the escape it cleaned up does not
    # exist. Its own detector only spoke when it removed something, ran from
    # 2026-08-10, and stayed silent until the day it started truncating the
    # wrong database. Both analyzer partitions are empty after real runs.
    #
    # What it did instead: `MIX_ENV` was scrubbed out of its child environment,
    # so `mix` defaulted to dev and it truncated `code_my_spec_dev` — the
    # database every agent shares — reporting the row count as escaped test
    # rows. It emptied it three times on 2026-08-13.
    #
    # Removed rather than guarded. A routine that truncates every table in
    # whichever database it happens to reach is worth having only against a
    # defect that is actually occurring, and this one was inventing its own
    # evidence. If residue returns it announces itself as phantom exunit
    # failures, which is a diagnosable symptom; a silent sweeper is not.

    case CodeMySpec.Tests.execute(args, environment: env, extra_env: extra_env) do
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
    # Stand down while a recording session owns this working copy. `5a1f6b9c`:
    # a replay landing on a cassette mid-rewrite fails on a half-written file
    # and reports failures that describe nothing about the code, and a second
    # suite saturating the machine times out the recorder's real DNS waits.
    #
    # Before the run rather than inside it, because by the time `mix spex` has
    # started, the damage this avoids has already been done.
    case CodeMySpec.RecordingLock.skip_reason(env.cwd) do
      nil -> run_spex(env, args)
      reason -> {:error, reason}
    end
  rescue
    exception -> crashed("spex", exception)
  end

  defp execute(source, _env, _args), do: {:error, "unknown analyzer source: #{source}"}

  defp run_spex(env, args) do
    case Spex.execute(args, environment: env, extra_env: AnalyzerEnv.extra_env(env, "spex")) do
      {:ok, failures, exit_code, output} ->
        {:ok,
         %{
           "source" => "spex",
           "exit_status" => exit_code,
           # Carried for the same reason exunit carries it: no failures plus a
           # nonzero exit means the suite did not run, and the server's refusal
           # is the only place that reason can still be read.
           "output" => cap(output || ""),
           "diagnostics" => Enum.map(failures, &spex_failure/1)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

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
  @doc false
  # Public only so the harness's own diagnostic can be asserted without a live
  # `mix spex`. Its absence is why a location fix shipped against the server's
  # copy and changed nothing here.
  def spex_failure(failure) do
    {file, line} = Runners.spex_location(failure.error, failure.spec_file)

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
