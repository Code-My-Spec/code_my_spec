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

  ## Execution and conversion are separate, because they are on separate machines

  `run/4` executes locally. `from_raw/2` converts what an analyzer printed into
  the same result map without executing anything, and that is the entry point
  the light harness's results come in through: the harness has the disk and the
  toolchain, the server has the `Problem` schema, so the harness runs the tool
  and sends the diagnostics and this converts them.

  `run/4` goes through `from_raw/2` as well. That is the point — a Problem row
  produced from a harness run and one produced from a server run come out of the
  same function, so the two paths cannot disagree about what a diagnostic means.

  The raw shape is per source and is the wire contract with `CmsHarness.Analysis`:

      compiler  %{"exit_status" => int, "diagnostics" => [%{"file", "line", "severity", "message"}]}
      credo     %{"exit_status" => int, "diagnostics" => [credo issue json]}
      exunit    %{"exit_status" => int, "execution_status" => "success"|"failure"|"error",
                  "output" => raw stdout, "stats" => map,
                  "diagnostics" => [%{"file", "line", "message"}]}
      spex      %{"exit_status" => int,
                  "diagnostics" => [%{"spex", "scenario", "file", "line", "message"}]}
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

    from_raw("compiler", %{
      "exit_status" => result.exit_code,
      "diagnostics" => result.data.compiler_results,
      "diagnostics_available" => Map.get(result.data, :diagnostics_available, true)
    })
  end

  # Credo scope follows the run kind: no args → project-wide sweep (full,
  # memoizable); path args → scoped `--files` run over the changed set
  # (partial — refreshes only those files' problems, mirrors the old
  # pipeline's per-turn scoping and its recorded cassettes).
  #
  # This one does not decompose into execute-then-convert the way the other
  # three do: `StaticRunner.run/3` owns availability checks and project
  # validation as well as the shell-out, and hands back `%Problem{}` structs
  # already. What it uses to build them is `ProblemConverter.from_credo/1` —
  # the same function `from_raw/2` calls — so the two paths still agree about
  # what a credo issue means, which is the property that matters.
  def run("credo", %Scope{} = scope, args, opts) do
    files = if args == [], do: nil, else: args
    runner_opts = [files: files] |> maybe_output_file(opts)

    case StaticRunner.run(scope, :credo, runner_opts) do
      {:ok, problems} ->
        {:ok,
         summarize(problems, if(problems == [], do: 0, else: 1), %{"issues" => length(problems)})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run("exunit", %Scope{} = scope, args, opts) do
    exec_opts = [environment: scope.environment] |> maybe_output_file(opts)

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

  def run("spex", %Scope{} = scope, args, opts) do
    exec_opts = [environment: scope.environment] |> maybe_output_file(opts)

    case Spex.execute(args, exec_opts) do
      {:ok, failures, exit_code, output} ->
        from_raw("spex", %{
          "exit_status" => exit_code,
          "output" => cap(output),
          "diagnostics" =>
            Enum.map(failures, fn failure ->
              {file, line} = spex_location(failure.error)

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
  anything.

  This is what a light harness's `analysis_result` goes through: the tool ran on
  the machine with the disk, and the `%Problem{}` schema is here.
  """
  @spec from_raw(String.t(), map()) :: {:ok, result()} | {:error, term()}
  def from_raw("compiler", raw) do
    problems = raw |> diagnostics() |> Enum.map(&ProblemConverter.from_compiler/1)
    {errors, warnings} = Enum.split_with(problems, &(&1.severity == :error))

    # A build that failed and said nothing is not a clean build.
    #
    # `Compile` deliberately returns no diagnostics when it cannot tell a real
    # compile error from a transient one — a config change forcing a rebuild,
    # build-lock contention, a project without the `:diagnostics` compiler. That
    # restraint is right: synthesising a problem out of Mix's progress banner
    # would block stops on a phantom.
    #
    # But the result was still recorded `:completed` with zero problems, and
    # `:completed` with zero problems is how this system says "looked, and it is
    # clean". So "the compiler failed and I could not tell you why" and "the code
    # is fine" arrived identically — the exact collapse this project exists to
    # prevent, on the analyzer that matters most.
    #
    # Failing the run says the third thing. It does not block: a failed run is
    # re-enqueued on the next stop rather than turned into a Problem, so no
    # phantom error blocks anybody. What it stops doing is claiming success.
    #
    # Keyed on whether diagnostics were *available*, not on the exit status.
    # `mix compile --return-errors` exits 0 even on a compile error — that is
    # what the flag is for — so exit status says nothing about whether the code
    # compiled. An earlier version of this check keyed on exit status and was
    # therefore inert for the exact case it was written for.
    if raw["diagnostics_available"] == false do
      {:error, {:compile_diagnostics_unavailable, raw["exit_status"]}}
    else
      {:ok,
       summarize(problems, raw["exit_status"], %{
         "errors" => length(errors),
         "warnings" => length(warnings)
       })}
    end
  end

  def from_raw("credo", raw) do
    problems = raw |> diagnostics() |> Enum.map(&ProblemConverter.from_credo/1)
    {:ok, summarize(problems, raw["exit_status"], %{"issues" => length(problems)})}
  end

  # `mix test` exited nonzero without reporting a single failure: bad args, a
  # compile error, missing deps. The suite never ran, so this result says
  # nothing about the code.
  #
  # Returning `{:ok, problems: []}` here was actively harmful. The Reconciler
  # clears a source's Problems wholesale before inserting, so an empty result
  # wiped every real exunit Problem and then finished the run `:completed` at
  # the current fingerprint — and `tests_passing` checks exactly those two
  # things (a fresh completed run, zero problems). A `mix test` that failed to
  # start therefore reported the component's tests as passing.
  #
  # Failing the run leaves it `:failed`: never fresh, never problem-clearing,
  # and re-enqueued on the next stop.
  def from_raw("exunit", %{"execution_status" => "error"} = raw) do
    {:error, {:test_suite_did_not_run, raw["exit_status"], error_excerpt(raw["output"])}}
  end

  # `mix test` exited without error having run nothing at all.
  #
  # Zero tests is not zero failures. The suite reports `execution_status:
  # success` with no diagnostics, which reaches `exunit_result/1` as `{:ok,
  # problems: []}` — identical to a clean sweep of the whole project — and the
  # Reconciler then clears every recorded exunit Problem and finishes the run
  # `:completed` at the current fingerprint. That is the trap the
  # `execution_status: "error"` clause above exists to close; this is the same
  # trap reached through a zero exit, which that clause cannot see.
  #
  # Observed: a 1,502ms `exunit []` against a project whose suite takes ~165s.
  # It was rejected downstream as `unknown_run`, which is luck rather than a
  # guard — accepted, it would have reported every component's tests as passing
  # on the strength of a run that executed nothing.
  #
  # Only the exact `%{"tests" => 0}` shape matches, so a payload carrying no
  # stats falls through to the clause below rather than being failed on a guess.
  def from_raw("exunit", %{"execution_status" => status, "stats" => %{"tests" => 0}} = raw)
      when is_binary(status) do
    {:error, {:test_suite_did_not_run, raw["exit_status"], error_excerpt(raw["output"])}}
  end

  # A run whose failures include "module ... is not available" lost its build
  # partway through. The analyzer shares `_build` with the agent, so an agent's
  # own `mix compile --force` wipes and rebuilds it while the suite is running
  # and modules disappear mid-run.
  #
  # What makes the signature strong rather than ambiguous: a genuinely missing
  # module fails compilation, so the suite would never have got as far as
  # producing test failures. Seeing this *among* test results therefore says
  # something about the build, not about the code.
  #
  # It has to be caught because it is indistinguishable from a real defect —
  # `module is not available` reads as a missing dependency, and the natural
  # response is to add code that is already there. Observed: 14 of 46 reported
  # failures were this, and nothing in the output said "your own build did it".
  #
  # Failed rather than reported, on the same reasoning as the two clauses
  # above. A failed run is re-enqueued on the next stop and costs one cycle;
  # phantom failures presented as real cost a turn and invite edits to code
  # that was never broken. Genuine failures in the same run are re-reported by
  # the rerun.
  def from_raw("exunit", %{"execution_status" => status} = raw) when is_binary(status) do
    case lost_build_failures(raw) do
      [] -> exunit_result(raw)
      lost -> {:error, {:build_changed_mid_run, length(lost), hd(lost)}}
    end
  end

  # The same trap as exunit above. `Spex.parse_jsonl/1` answers `{:ok, []}` for
  # a missing file, so "the run never happened" and "everything is clean" are
  # indistinguishable by the failure list alone — the nonzero exit is the only
  # thing separating them. Fail the run rather than let an empty result clear
  # every spex Problem and finish `:completed`.
  #
  # The excerpt is the difference between a failure you can act on and one you
  # cannot. This said `{:spex_suite_did_not_run, code}` and nothing else, so a
  # sweep that died — a spex that would not compile, a crash before
  # `:suite_finished` — left no account of why anywhere: `harness.log` records
  # only the command, and the output was discarded at `Spex.execute`. exunit has
  # carried its excerpt since `runners.ex:214`; this is the same tuple, one
  # analyzer late.
  def from_raw("spex", raw) do
    exit_code = raw["exit_status"]

    case {diagnostics(raw), exit_code} do
      {[], code} when code != 0 ->
        {:error, {:spex_suite_did_not_run, code, error_excerpt(raw["output"])}}

      {failures, code} ->
        {:ok, spex_result(failures, code)}
    end
  end

  # An exunit payload with no `execution_status`, or any source this server does
  # not know, is refused rather than read charitably. Both would otherwise
  # produce a `:completed` run with no problems, which is the one answer that
  # must never be reached by accident.
  def from_raw(source, _raw), do: {:error, {:unreadable_result, source}}

  defp spex_result(failures, exit_code) do
    problems =
      failures
      |> Enum.map(&spex_failure_to_problem/1)
      |> Enum.map(&%{&1 | source: "spex"})

    summarize(problems, exit_code, %{"failures" => length(failures)})
  end

  # `diagnostics` is required, not defaulted. A payload arriving without the key
  # is version skew or a bug, and defaulting it to `[]` would report the source
  # clean — which is the failure this whole path exists to prevent. It raises.
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
        ProblemConverter.from_test_failure(%CodeMySpec.Tests.TestError{
          file: failure["file"],
          line: failure["line"],
          message: failure["message"]
        })
      end)
      |> Enum.map(&%{&1 | source: "exunit"})

    {:ok,
     %{
       problems: problems,
       output: cap(raw["output"] || ""),
       exit_status: raw["exit_status"],
       stats: raw["stats"] || %{}
     }}
  end

  # A module that vanished, or a dependency's function that did.
  #
  # The first signature was `module ... is not available`. The second is the
  # same event seen one level in: a dep whose beams are being rewritten answers
  # `function Jason.Decoder.parse/2 is undefined or private` while the suite is
  # mid-run. Observed exactly that, as two failures in `Notifications` — a
  # context that has nothing to do with JSON decoding and was not being edited.
  #
  # Restricted to modules outside this application's namespaces, and that
  # restriction is the whole care in it. A dep function undefined at *runtime*
  # when the dep compiled means its beams moved underneath the run. One of our
  # own modules is a different matter: an undefined local function is a warning
  # rather than a compile error, so it genuinely can fail at runtime, and
  # swallowing that would hide a real defect behind a build excuse.
  @foreign_undefined ~r/function (?!CodeMySpec|CmsHarness|CodeMySpecWeb|CodeMySpecSpex)[A-Z][\w.]*\.\w+\/\d+ is undefined/

  defp lost_build_failures(raw) do
    raw
    |> diagnostics()
    |> Enum.map(& &1["message"])
    |> Enum.filter(&lost_build?/1)
  end

  defp lost_build?(message) when is_binary(message) do
    message =~ ~r/module .+ is not available/ or message =~ @foreign_undefined
  end

  defp lost_build?(_message), do: false

  defp summarize(problems, exit_status, stats) do
    %{
      problems: problems,
      output: cap(format_problem_lines(problems)),
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

  # Where a spex failure belongs: its spec, not wherever the exception was
  # raised.
  #
  # `error.file` is the top stacktrace frame. For an assertion inside the spec
  # those are the same file, which is why this held for so long. For anything
  # that *raises* from library code they are not: two cassette failures filed
  # against `lib/req_cassette/plug.ex:481` and `:607`, the plug that raised,
  # with nothing left pointing at the specs that failed.
  #
  # That costs three things. The story link is gone — a spex path carries its
  # story id and a library path carries nothing — so the finding cannot be
  # traced back to the work. It reads as a bug in the library rather than a
  # cassette that was never recorded. And under `:block_changed` it blocks
  # whoever touches the library, who is never the person who can fix it.
  #
  # The spec frame is still in the stacktrace, so this takes the file *and* the
  # line from the same frame — taking only the file would pair a spec path with
  # a line number from somewhere else, which is worse than either alone.
  @doc false
  # Public only so the rule can be asserted without a live `mix spex` — the
  # half that was wrong is the choice of location, not the conversion.
  def spex_location(nil), do: {nil, nil}

  def spex_location(error) do
    case spec_frame(error.stacktrace) do
      # No spec frame at all — a raise from a setup block, a shared fixture, or
      # a plug, with nothing in the trace naming the spec that was running.
      #
      # This used to fall back to `error.file`, on the reasoning that filing it
      # somewhere beat filing it nowhere. That was wrong, and it recurred with
      # the fix in place: `ReqCassette.Plug` raised from a cassette miss and two
      # spex failures were filed at `lib/req_cassette/plug.ex:481` — no story,
      # no criterion, and blocking for whoever next touches the plug. Which is
      # the whole defect the location rule was written to remove.
      #
      # A spex failure belongs to a spec or to no file. Saying "somewhere" when
      # the somewhere is wrong is the louder version of saying nothing.
      nil -> spec_file_fallback(error)
      frame -> {frame_get(frame, "file"), frame_get(frame, "line")}
    end
  end

  # `error.file` when it is itself a spec, and nothing otherwise.
  #
  # The rule above is "a spex failure belongs to a spec or to no file", and the
  # reason it stopped reading `error.file` is that the top stacktrace frame is
  # often library code — `ReqCassette.Plug` raised and two failures were filed
  # against the plug. Applying the same `_spex.exs` test the stacktrace search
  # uses keeps that property: library paths are still refused.
  #
  # What it recovers is the failure with no usable stacktrace at all. Those were
  # landing on `unknown`, which reads to an agent as "a spex failed somewhere"
  # and is one step better than nothing — the file was right there in the
  # payload, unused.
  defp spec_file_fallback(error) do
    file = error_get(error, :file)

    if is_binary(file) and String.ends_with?(file, "_spex.exs") do
      {file, error_get(error, :line)}
    else
      {nil, nil}
    end
  end

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
