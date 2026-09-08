defmodule CodeMySpec.Compile do
  @moduledoc """
  Compile context for executing and parsing Elixir compilation results.
  Provides a clean functional interface for compilation execution and diagnostics analysis.

  Requires the target project to have `:diagnostics` (and optionally `:spex`) in its
  compilers list via `client_utils`. The `:diagnostics` compiler writes a JSONL file
  containing all diagnostics from every compiler in the pipeline.
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.TempFile

  @doc """
  Execute mix compile synchronously and read the diagnostics JSONL file.

  Runs `mix compile --return-errors` with `DIAGNOSTICS_OUTPUT` set to a temp file.
  The `:diagnostics` compiler (from client_utils) writes all diagnostics to that file.

  ## Options

  - `cwd` - Working directory to run the command in (optional)
  - `output_file` - Path for diagnostics JSONL output (optional, defaults to temp file)

  ## Returns

  Map with structure:
  ```
  %{
    status: :ok | :error,
    data: %{compiler_results: [map()] | string},
    exit_code: integer,
    output_file: string
  }
  ```
  """
  @spec execute(keyword()) :: map()
  def execute(opts \\ []) do
    output_file = Keyword.get_lazy(opts, :output_file, &create_temp_file_path/0)
    env = Keyword.fetch!(opts, :environment)
    injected_file = Keyword.has_key?(opts, :output_file)

    cmd_opts = [
      stderr_to_stdout: true,
      # clean_otp_env clears the Burrito release's ROOTDIR/BINDIR/RELEASE_*
      # so the child `mix`/`erl` boots from the user's installed OTP, not our
      # extracted ERTS (which otherwise crashes with "cannot get bootfile").
      env:
        [
          {"MIX_ENV", "test"},
          {"DIAGNOSTICS_OUTPUT", output_file}
        ] ++
          Keyword.get(opts, :extra_env, []) ++
          CodeMySpec.Environments.clean_otp_env()
    ]

    Logger.debug("[Compile] output_file=#{output_file}")
    Logger.debug("[Compile] cwd=#{inspect(env.cwd)}")
    Logger.debug("[Compile] env=#{inspect(cmd_opts[:env])}")

    {output, exit_code} =
      Environments.cmd(env, "mix", ["compile", "--return-errors"], cmd_opts)

    Logger.debug("[Compile] exit_code=#{exit_code}")

    Logger.debug(
      "[Compile] output_file exists?=#{output_exists?(env, output_file, injected_file)}"
    )

    Logger.debug("[Compile] raw output (first 500 chars): #{String.slice(output, 0, 500)}")

    {result_data, diagnostics_available} =
      case read_output(env, output_file, injected_file) do
        {:ok, content} when byte_size(content) > 0 ->
          Logger.debug("[Compile] Read JSONL from diagnostics file (#{byte_size(content)} bytes)")
          {parse_jsonl(content), true}

        {:ok, _} ->
          Logger.debug("[Compile] Diagnostics file exists but empty — clean compilation")
          {[], true}

        {:error, _reason} when exit_code == 0 ->
          # `mix compile --return-errors` exits 0 even on a compile error — that
          # is what the flag is for — so a zero exit says nothing about whether
          # the code compiled. The only thing that distinguishes "compiled
          # cleanly" from "nobody was recording" is whether the :diagnostics
          # compiler wrote its file, and here it did not.
          Logger.warning(
            "[Compile] no diagnostics file was written. The :diagnostics compiler " <>
              "(from client_utils) is what produces it, so this project is almost " <>
              "certainly missing it from its `compilers:` list. Nothing was checked."
          )

          {[], false}

        {:error, _reason} ->
          # Non-zero exit, no diagnostics file. This is NOT automatically a code
          # error: a config/mix.exs change forcing a rebuild, the "you must
          # restart after changing configuration files" RuntimeError, build-lock
          # contention, or a project missing the :diagnostics compiler all exit
          # non-zero with no diagnostics. Only synthesize a blocking problem when
          # the raw output actually contains a genuine compiler error marker;
          # otherwise treat it as transient so the stop hook isn't blocked by a
          # phantom error parsed out of Mix's progress banner ("==> boundary").
          case extract_compiler_errors(output) do
            [] ->
              Logger.warning(
                "[Compile] exit #{exit_code}, no diagnostics file and no compiler error " <>
                  "markers in output — treating as transient (config change, lock " <>
                  "contention, or missing :diagnostics compiler). First 500 chars: " <>
                  String.slice(output, 0, 500)
              )

              {[], false}

            errors ->
              Logger.warning(
                "[Compile] exit #{exit_code}, diagnostics file not written; recovered " <>
                  "#{length(errors)} compiler error(s) from raw output"
              )

              {errors, true}
          end
      end

    %{
      status: if(exit_code == 0, do: :ok, else: :error),
      data: %{
        compiler_results: relativize_diagnostics(result_data, env.cwd),
        diagnostics_available: diagnostics_available
      },
      exit_code: exit_code,
      output_file: output_file
    }
  end

  # A diagnostic's paths have to leave here relative to the root the compiler
  # ran under, and they do not arrive that way from every environment.
  #
  # `CodeMySpec.BddSpecs.Spex.relativize_error_file/2` is this exact fix for the
  # spex path (`cc643bf3`, `fa76604b`), and the compiler path never got it.
  # `Analysis.Reconciler.patch_file_path/1` sees the result and says so —
  # "problem recorded with an absolute file_path … this row will be deleted by
  # the next file sync" — but only warns, deliberately, since rejecting would
  # roll back every other problem from the same source.
  #
  # What that costs: `clear_problems_for_missing_files/2` deletes any Problem
  # whose path is not in the current file list, and that list is relative, so
  # the row is removed on the next sync as though its file had been deleted —
  # while the stop hook has already blocked on it, and the next compile writes a
  # fresh one. The finding is real, `list_problems` cannot see it, and it
  # returns on the next sweep. Seven agents in one evening reported the same
  # symptom from that loop (b4c34f92 collects them).
  #
  # `env.cwd` is the right root for every environment, including the one that
  # produces the absolute paths: `Container.create/1` sets `cwd` to the
  # container's own workdir (`/workspace`), which is exactly the prefix its
  # compiler reports under. A path from some *other* root stays absolute, per
  # `Path.relative_to/2`, and the reconciler's warning still catches it.
  #
  # Covers both ways diagnostics arrive. A caller-supplied `:output_file` — the
  # stop hook's `test_output_files` — reads a host-local fixture but is parsed
  # by this same function, so it is relativized here too.
  @doc false
  # Public so the rule can be asserted without running a compiler, the same
  # reason `parse_jsonl/1` and `extract_compiler_errors/1` are.
  @spec relativize_diagnostics([map()], String.t() | nil) :: [map()]
  def relativize_diagnostics(diagnostics, cwd) when is_binary(cwd) and is_list(diagnostics) do
    Enum.map(diagnostics, &relativize_diagnostic(&1, cwd))
  end

  def relativize_diagnostics(diagnostics, _cwd), do: diagnostics

  defp relativize_diagnostic(%{} = diagnostic, cwd) do
    Enum.reduce(~w(file source), diagnostic, fn key, acc ->
      case Map.get(acc, key) do
        path when is_binary(path) -> Map.put(acc, key, Path.relative_to(path, cwd))
        _ -> acc
      end
    end)
  end

  defp relativize_diagnostic(diagnostic, _cwd), do: diagnostic

  @doc """
  Execute mix compile asynchronously with callback.

  Wraps `execute/1` in a Task and invokes the callback when complete.

  ## Parameters

  - `opts` - Options to pass to `execute/1` (e.g., `cwd: "/path"`)
  - `interaction_id` - Interaction identifier for status updates
  - `on_complete` - Callback function invoked with compilation results

  ## Returns

  `:ok` - Compilation started successfully in background task
  """
  @spec execute_async(keyword(), String.t(), (map() -> any())) :: :ok
  def execute_async(opts, _interaction_id, on_complete) do
    Task.start(fn ->
      result = execute(opts)
      on_complete.(result)
    end)

    :ok
  end

  @doc """
  Parse JSONL content (one JSON object per line) into a list of maps.
  """
  def parse_jsonl(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{"message" => line, "severity" => "error"}
      end
    end)
  end

  # Markers that prove the raw compiler output contains a genuine code error.
  @compiler_error_markers [
    "** (CompileError)",
    "** (SyntaxError)",
    "** (TokenMissingError)",
    "== Compilation error in file"
  ]

  # Markers that prove a non-zero exit is an infrastructure/transient condition,
  # not a code error. When present we never synthesize a blocking problem.
  @transient_markers [
    "could not compile application",
    "You must restart your server"
  ]

  @doc """
  Extract genuine compiler errors from raw `mix compile` stdout.

  Used only as a fallback when the `:diagnostics` JSONL file was not written and
  the compile exited non-zero. Returns a list of `%{"message" => ..., "severity"
  => "error"}` maps for each genuine error line, or `[]` when the output is a
  transient/infrastructure failure (config change "must restart", lock
  contention) or merely Mix progress banners with no real diagnostics.
  """
  @spec extract_compiler_errors(String.t()) :: [map()]
  def extract_compiler_errors(output) when is_binary(output) do
    cond do
      # Asked first, because this is the failure that *looks* transient and
      # never heals. It has to beat the transient markers rather than sit after
      # them.
      unsatisfied_deps?(output) ->
        [unsatisfied_deps_problem(output)]

      Enum.any?(@transient_markers, &String.contains?(output, &1)) ->
        []

      true ->
        output
        |> String.split("\n")
        |> Enum.filter(&compiler_error_line?/1)
        |> Enum.map(&%{"message" => String.trim(&1), "severity" => "error"})
    end
  end

  # The failure that looks transient and never heals.
  #
  # `mix.lock` is committed, so a dependency added in one worktree reaches every
  # other the moment it pulls — and `deps/` is per-worktree and does not follow.
  # The checkout then exits 1 with "Unchecked dependencies" and no diagnostics
  # file, which is exactly the shape of a config change or lock contention, so
  # it was classified as transient. It is not: nothing heals it but `deps.get`.
  #
  # Measured on 2026-09-08: `ex_slop` and an alloy fork landed on main, and
  # seven checkouts on one machine began failing every analyzer in about a
  # second. The run stayed open, the output was discarded, and every stop said
  # "analysis pending" — for hours, with the one line that names the cause
  # sitting in a `Logger.warning` nobody was reading.
  #
  # Reported as a problem rather than as an error, because the agent is standing
  # in that checkout and can fix it. John: "shouldn't we send a message to the
  # model in that case and tell it that it needs to fix that thing? Isn't that a
  # deliverable message?" It is — the stop menu ranks problems first, so the
  # agent is told before it is asked to do anything else, and told what to run.
  @unsatisfied_deps_markers [
    "Unchecked dependencies",
    "Can't continue due to errors on dependencies"
  ]

  defp unsatisfied_deps?(output),
    do: Enum.any?(@unsatisfied_deps_markers, &String.contains?(output, &1))

  defp unsatisfied_deps_problem(output) do
    %{
        "message" =>
          "This checkout cannot satisfy its own mix.lock, so no analyzer can run here. " <>
            "Run `mix deps.get` in this working copy. " <>
            "`mix.lock` is committed and `deps/` is not, so a dependency added in another " <>
            "checkout arrives with the next pull and has to be fetched once. " <>
            "Details: " <> first_dependency_complaint(output),
      "severity" => "error"
    }
  end

  # The lines mix prints under the banner name which dependencies, and that is
  # the actionable half — "req is out of date" tells you the pull moved it,
  # where the banner alone reads as a broken machine.
  defp first_dependency_complaint(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not Enum.any?(@unsatisfied_deps_markers, fn m -> String.contains?(&1, m) end)))
    |> Enum.take(6)
    |> Enum.map_join(" ", &String.trim/1)
    |> String.slice(0, 300)
  end

  defp compiler_error_line?(line) do
    trimmed = String.trim_leading(line)

    Enum.any?(@compiler_error_markers, &String.starts_with?(trimmed, &1)) or
      String.starts_with?(trimmed, "error:")
  end

  # Two different files wear the `output_file` name here, and they live on
  # different machines.
  #
  # The generated temp path is handed to the child as `DIAGNOSTICS_OUTPUT`, so
  # the child writes it wherever it is running — inside the environment. Reading
  # that with File.read looks on the machine that *launched* the run, misses,
  # and falls into the "no diagnostics" branch below, which reports a clean
  # compilation. That is the most dangerous possible wrong answer.
  #
  # A caller-provided path is the cassette seam: `Analysis.Execution` only
  # populates `:output_file` from the stop hook's `test_output_files` param, so
  # it is a fixture on the harness's own disk, put there by the spex suite and
  # never by the project under test. That one is genuinely host-local.
  defp read_output(_env, path, true), do: File.read(path)
  defp read_output(env, path, false), do: Environments.read_file(env, path)

  defp output_exists?(_env, path, true), do: File.exists?(path)
  defp output_exists?(env, path, false), do: Environments.file_exists?(env, path)

  # `System.unique_integer/1` alone named this, and it is unique only within one
  # BEAM while the path is machine-wide — so a concurrent process compiling a
  # project that *does* have the `:diagnostics` compiler could write the file
  # this one then read. See `CodeMySpec.TempFile`.
  defp create_temp_file_path, do: TempFile.path("compile_diagnostics", ".jsonl")
end
