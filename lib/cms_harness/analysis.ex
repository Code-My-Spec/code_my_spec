defmodule CmsHarness.Analysis do
  @moduledoc """
  Run one analyzer against the working copy and say what it printed.

  The half of analysis that needs this disk and a toolchain. Nothing here
  knows what a Problem is: it runs the tool and hands back raw diagnostics; the
  server converts them (`ProblemConverter`). The executors are the shared
  `CodeMySpec.Compile`, `CodeMySpec.Tests`, `CodeMySpec.BddSpecs.Spex`,
  `StaticAnalysis.CredoRun` and `StaticAnalysis.SobelowRun`.

  ## The wire shape

  `run/4` answers `{:ok, result}` where result is the map the server's
  `Analysis.Runners.from_raw/2` reads:

      %{
        "source" => "compiler" | "credo" | "exunit" | "spex" | "sobelow",
        "exit_status" => integer() | nil,
        "diagnostics" => [map()],          # raw, source-specific
        "output" => String.t() | nil,      # raw stdout
        "diagnostics_available" => bool,   # compiler only
        "execution_status" => String.t(),  # exunit only
        "stats" => map() | nil,            # exunit only
        "partition" => String.t()          # exunit and spex: which database answered
      }

  and `{:error, reason}` when the tool did not run. The two are never merged:
  "failed to start" and "ran clean" both print no diagnostics, and must not
  reach the server as the same answer.
  """

  require Logger

  alias CmsHarness.AnalyzerEnv
  alias CmsHarness.RunLink
  alias CodeMySpec.Analysis.RunNode
  alias CodeMySpec.Analysis.Runners
  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Compile
  alias CodeMySpec.DurableRun
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.StaticAnalysis.CredoRun
  alias CodeMySpec.StaticAnalysis.SobelowRun

  @output_cap 100_000

  @sources ~w(compiler credo exunit spex sobelow)

  @doc "The analyzer sources this harness knows how to run."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  Run `source` against `project`'s working copy.

  `args` are the analyzer's own arguments — empty for the stop hook's
  whole-project sweep, paths for a targeted run. `run_id` is the server's
  ledger row for this execution; every real dispatch has one, direct calls
  may omit it. The optional `:output_capture` IO device receives command
  output as it arrives. Its caller owns and closes it, allowing captured
  output to survive termination of the analyzer task.
  """
  @spec run(map(), String.t(), [String.t()], integer() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(project, source, args \\ [], run_id \\ nil, opts \\ [])
      when is_binary(source) and is_list(args) do
    env =
      ExecutionContext.new(:local, project.root,
        metadata: %{
          output_capture: Keyword.get(opts, :output_capture),
          run_id: run_id,
          durable_run: Keyword.get(opts, :durable_run)
        }
      )

    started = System.monotonic_time(:millisecond)

    result =
      fn -> execute(source, env, args) end
      |> heal_stale_deps(fn -> deps_get(env) end)
      |> stamp_partition(env, source)

    Logger.info(
      "[CmsHarness] #{source} #{inspect(args)} in #{project.root}#{run_id_suffix(run_id)} " <>
        "took #{System.monotonic_time(:millisecond) - started}ms — #{describe_outcome(result)}"
    )

    result
  end

  @doc """
  Run, and if `mix` refused because `deps/` is behind `mix.lock`, fetch once
  (under a per-checkout lock) and run again. A failed fetch is reported as
  that, not as whatever the analyzer made of mix's refusal.

  `run` and `fetch` are arguments so the decision is testable without `mix`.
  """
  @spec heal_stale_deps((-> term()), (-> :ok | {:error, String.t()})) :: term()
  def heal_stale_deps(run, fetch) do
    result = run.()

    if stale_deps?(result) do
      case fetch.() do
        :ok -> run.()
        {:error, output} -> {:error, deps_get_failed(output)}
      end
    else
      result
    end
  end

  defp stale_deps?({:error, reason}) when is_binary(reason), do: stale_marker?(reason)

  defp stale_deps?({:ok, %{} = result}),
    do: result |> inspect(limit: :infinity) |> stale_marker?()

  defp stale_deps?(_result), do: false

  # Mix's own banner, or the line `Compile` and `CredoRun` turn it into.
  defp stale_marker?(text),
    do:
      Compile.unsatisfied_deps?(text) or text =~ "cannot satisfy its own mix.lock" or
        text =~ "deps out of date with mix.lock"

  defp deps_get_failed(output) do
    "deps out of date with mix.lock, and `mix deps.get` in this working copy failed: " <>
      (output |> String.trim() |> String.slice(0, 400))
  end

  @doc """
  Run a mix command in `env`'s checkout the way an analyzer run is: if mix
  refused because `deps/` is behind `mix.lock`, fetch once and run it again.
  For the promotion gate's test-database reset.
  """
  @spec heal(ExecutionContext.t(), (-> term())) :: term()
  def heal(env, run), do: heal_stale_deps(run, fn -> deps_get(env) end)

  # The checkout's own `deps/`. MIX_ENV set: the harness runs as `harness`,
  # which a project's config need not define.
  defp deps_get(env) do
    serialize_deps_get(env.cwd, fn ->
      case ExecutionContexts.cmd(env, "mix", ["deps.get"],
             stderr_to_stdout: true,
             env: [{"MIX_ENV", "dev"}]
           ) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, out}
      end
    end)
  end

  @doc "Run `fun` holding the checkout's `deps.get` lock, so concurrent runs fetch one at a time."
  # A `:global` lock id must be `{ResourceId, RequesterId}`; anything else
  # raises `function_clause`.
  @spec serialize_deps_get(String.t(), (-> result)) :: result when result: term()
  def serialize_deps_get(cwd, fun),
    do: :global.trans({{__MODULE__, :deps_get, cwd}, self()}, fun)

  @doc """
  The checkout's commit and whether its tree has uncommitted changes, read
  around a run so the server can record which commit it answered for.

  Dirty is measured as `Promotion.Steps.precheck/2` measures it (tracked files
  only, submodules ignored), so a run's clean tree and a promotion's clean tree
  are the same fact. `tree` is the commit's git tree, which a pass answers for
  (story 1174); nil unless the tree is clean. Nil for whatever `git` could not
  answer.
  """
  @spec tree_state(ExecutionContext.t()) :: %{
          commit: String.t() | nil,
          dirty: boolean() | nil,
          tree: String.t() | nil
        }
  def tree_state(env) do
    {commit, tree} = head(env)
    dirty = tree_dirty(env)
    %{commit: commit, dirty: dirty, tree: if(dirty == false, do: tree)}
  end

  # One call, so the commit and its tree cannot straddle a commit landing.
  defp head(env) do
    case ExecutionContexts.cmd(env, "git", ["rev-parse", "HEAD", "HEAD^{tree}"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.split(out, "\n", trim: true) do
          [commit, tree] -> {commit, tree}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp tree_dirty(env) do
    case ExecutionContexts.cmd(
           env,
           "git",
           ["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  end

  defp run_id_suffix(nil), do: ""
  defp run_id_suffix(run_id), do: " (run #{run_id})"

  @doc """
  What a finished run found, for the line that says it finished.

  Finding count and exit status, so `harness.log` says what a run found and
  not just how long it took.
  """
  @spec describe_outcome({:ok, map()} | {:error, term()}) :: String.t()
  def describe_outcome({:ok, %{"diagnostics" => diagnostics} = result})
      when is_list(diagnostics) do
    "#{length(diagnostics)} finding(s), exit #{Map.get(result, "exit_status", "?")}"
  end

  # No diagnostics key: "nothing reported" is not "nothing found".
  def describe_outcome({:ok, _result}), do: "no diagnostics reported"

  def describe_outcome({:error, reason}) do
    "failed: " <> (reason |> to_string() |> String.slice(0, 160))
  end

  # Which test database answered, on the two sources that open one: a partition
  # with a drifted schema otherwise reads as broken code.
  # See knowledge/harness, "Analysis".
  defp stamp_partition({:ok, result}, env, source) when source in ~w(exunit spex) do
    case List.keyfind(AnalyzerEnv.extra_env(env, source), "MIX_TEST_PARTITION", 0) do
      {_key, partition} -> {:ok, Map.put(result, "partition", partition)}
      nil -> {:ok, result}
    end
  end

  defp stamp_partition(result, _env, _source), do: result

  defp execute("compiler", env, args) do
    result =
      Compile.execute(
        execution_context: env,
        extra_env: AnalyzerEnv.extra_env(env, "compiler"),
        force: "--force" in args
      )

    {:ok,
     %{
       "source" => "compiler",
       # Derived from the diagnostics: `--return-errors` exits 0 on findings.
       "exit_status" => compiler_exit_status(result),
       "diagnostics" => Enum.map(result.data.compiler_results, &stringify/1),
       # Whether anything was recording: tells "clean" from "nobody looked".
       "diagnostics_available" => Map.get(result.data, :diagnostics_available, true),
       # What the compiler printed. See
       # .code_my_spec/rules/analysis_output_fidelity.md.
       "output" => result.output
     }}
  rescue
    exception -> crashed("compiler", exception)
  end

  defp execute("credo", env, args) do
    files = if args == [], do: nil, else: args

    extra_env =
      AnalyzerEnv.extra_env(env, "credo") ++
        RunNode.credo_env(RunLink.env(env.cwd, env.metadata[:run_id]))

    case CredoRun.run(env, files: files, extra_env: extra_env) do
      {:ok, issues, output} ->
        {:ok,
         %{
           "source" => "credo",
           # From the issue count, as `Runners.run/4` derives it locally.
           "exit_status" => if(issues == [], do: 0, else: 1),
           "diagnostics" => issues,
           # What credo printed (JSON). See
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
    extra_env =
      AnalyzerEnv.extra_env(env, "exunit") ++
        durable_stream_env(env) ++
        if(env.metadata[:durable_run], do: [], else: RunLink.env(env.cwd, env.metadata[:run_id]))

    # No pre-run truncate, deliberately. See knowledge/harness, "Analysis".

    case CodeMySpec.Tests.execute(args, execution_context: env, extra_env: extra_env) do
      {:ok, test_run} ->
        {:ok,
         %{
           "source" => "exunit",
           "exit_status" => test_run.exit_code,
           # Tells "ran and failed" from "never started"; the server refuses
           # to reconcile the second, which would clear every exunit Problem.
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
    # Stand down, before starting, while a recording session owns this copy:
    # a replay mid-rewrite reads half-written cassettes.
    case CodeMySpec.RecordingLock.skip_reason(env.cwd) do
      nil -> run_spex(env, args)
      reason -> {:error, reason}
    end
  rescue
    exception -> crashed("spex", exception)
  end

  defp execute("sobelow", env, _args) do
    case SobelowRun.run(env, extra_env: AnalyzerEnv.extra_env(env, "sobelow")) do
      {:ok, findings, output} ->
        {:ok,
         %{
           "source" => "sobelow",
           # From the finding count, as for credo.
           "exit_status" => if(findings == [], do: 0, else: 1),
           "diagnostics" => findings,
           "output" => output
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  rescue
    exception -> crashed("sobelow", exception)
  end

  defp execute(source, _env, _args), do: {:error, "unknown analyzer source: #{source}"}

  @doc """
  The compiler source's exit_status, derived from its diagnostics rather than
  `mix compile --return-errors`'s own exit code — which stays 0 even on a
  genuine warning or error. Non-zero whenever any diagnostic was found; a
  genuinely non-zero exit (a real crash) is never lowered.

  Public so the convention can be asserted without shelling out to `mix` —
  the same reason `CodeMySpec.Compile.relativize_diagnostics/2` is.
  """
  @spec compiler_exit_status(map()) :: integer()
  def compiler_exit_status(%{exit_code: exit_code, data: %{compiler_results: []}}),
    do: exit_code

  def compiler_exit_status(%{exit_code: exit_code}), do: max(exit_code, 1)

  # Linked like exunit's, so a spex run streams too; the formatter is what sends.
  defp run_spex(env, args) do
    {args, link} =
      case if(env.metadata[:durable_run],
             do: [],
             else: RunLink.env(env.cwd, env.metadata[:run_id])
           ) do
        [] ->
          if env.metadata[:durable_run],
            do: {args ++ ["--formatter=ClientUtils.TestFormatter"], []},
            else: {args, []}

        link ->
          {args ++ ["--formatter=ClientUtils.TestFormatter"], link}
      end

    result =
      Spex.execute(args,
        execution_context: env,
        extra_env: AnalyzerEnv.extra_env(env, "spex") ++ durable_stream_env(env) ++ link
      )

    if link != [], do: RunLink.exited(env.metadata[:run_id])

    case result do
      {:ok, failures, exit_code, output} ->
        {:ok,
         %{
           "source" => "spex",
           "exit_status" => exit_code,
           # No failures plus a nonzero exit means the suite did not run; the
           # output is where the reason can be read.
           "output" => output || "",
           "diagnostics" => Enum.map(failures, &spex_failure/1)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp durable_stream_env(%{metadata: %{durable_run: id}}) when is_integer(id),
    do: [{"CMS_RUN_EVENT_STREAM", DurableRun.stream_path(id)}]

  defp durable_stream_env(_env), do: []

  defp crashed(source, exception) do
    Logger.error("[CmsHarness] #{source} crashed: #{Exception.message(exception)}")
    {:error, "#{source} crashed: #{Exception.message(exception)}"}
  end

  # Reduced to the three fields the server's converter reads.
  defp test_failure(%{error: nil} = failure) do
    %{
      "file" => nil,
      "line" => nil,
      "name" => failure.full_title || failure.title,
      "test" => failure.full_title || failure.title,
      "message" => failure.full_title || failure.title
    }
  end

  defp test_failure(%{error: error} = failure) do
    %{
      "file" => error.file,
      "line" => error.line,
      "name" => failure.full_title || failure.title,
      "test" => failure.full_title || failure.title,
      "message" => error.message
    }
  end

  # Location via the shared `Runners.spex_location/2`, never a second copy.
  @doc "One spex failure as the problem map the server receives, located at its spec file and line."
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

  # Guards against an atom-keyed diagnostic reaching the wire.
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

  @doc """
  Analyzer output made safe for the channel: invalid UTF-8 scrubbed, then the
  start and end kept within #{@output_cap} bytes (markers included), both cuts
  on character boundaries. The server's cap is idempotent, so receiving this
  payload cannot discard its failure tail.
  """
  @spec cap(binary()) :: String.t()
  defdelegate cap(output), to: Runners
end
