defmodule CodeMySpec.Compile do
  @moduledoc """
  Compile context for executing and parsing Elixir compilation results.
  Provides a clean functional interface for compilation execution and diagnostics analysis.

  Requires the target project to have `:diagnostics` (and optionally `:spex`) in its
  compilers list via `client_utils`. The `:diagnostics` compiler writes a JSONL file
  containing all diagnostics from every compiler in the pipeline.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpec.TempFile]

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
  - `force` - recompile everything (`--force`), so no diagnostic is skipped

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
      # The environment adapter scrubs inherited OTP/release variables while
      # preserving these explicit choices. Appending clean_otp_env here would
      # clear MIX_ENV and the analyzer's MIX_BUILD_PATH after setting them.
      env:
        [
          {"MIX_ENV", "test"},
          {"DIAGNOSTICS_OUTPUT", output_file}
        ] ++
          Keyword.get(opts, :extra_env, [])
    ]

    Logger.debug("[Compile] output_file=#{output_file}")
    Logger.debug("[Compile] cwd=#{inspect(env.cwd)}")
    Logger.debug("[Compile] env=#{inspect(cmd_opts[:env])}")

    {output, exit_code} =
      Environments.cmd(env, "mix", compile_args(opts), cmd_opts)

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
          # `--return-errors` exits 0 on a compile error, so a zero exit with no
          # diagnostics file means nobody was recording, not a clean compile.
          Logger.warning(
            "[Compile] no diagnostics file was written. The :diagnostics compiler " <>
              "(from client_utils) is what produces it, so this project is almost " <>
              "certainly missing it from its `compilers:` list. Nothing was checked."
          )

          {[], false}

        {:error, _reason} ->
          # Non-zero exit, no diagnostics file: not necessarily a code error
          # (config change, "must restart", lock contention, missing
          # :diagnostics compiler). Only genuine compiler error markers become
          # problems, so Mix's progress banner never blocks a stop.
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
      output_file: output_file,
      # The tool's own stdout, kept whole. See
      # `.code_my_spec/rules/analysis_output_fidelity.md`.
      output: output
    }
  end

  # Diagnostic paths leave here relative to `env.cwd` (a container reports
  # under its workdir). A path from another root stays absolute and the
  # Reconciler warns on it. Applies to injected `:output_file` fixtures too.
  # See knowledge/analysis, "Problem file paths are relative".
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
      # First: it looks transient but never heals.
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

  # Unsatisfied deps look transient but never heal without `mix deps.get`
  # (`mix.lock` is committed, `deps/` is per-checkout). Reported as a problem
  # so the agent in that checkout is told what to run.
  # See knowledge/analysis, "Compile".
  @unsatisfied_deps_markers [
    "Unchecked dependencies",
    "Can't continue due to errors on dependencies"
  ]

  @doc """
  Whether `mix` refused because this checkout's `deps/` cannot satisfy its own
  `mix.lock` — the refusal every analyzer hits after a pull moves the lock.
  """
  @spec unsatisfied_deps?(String.t()) :: boolean()
  def unsatisfied_deps?(output) when is_binary(output),
    do: Enum.any?(@unsatisfied_deps_markers, &String.contains?(output, &1))

  def unsatisfied_deps?(_output), do: false

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
    |> Enum.drop_while(
      &(not Enum.any?(@unsatisfied_deps_markers, fn m -> String.contains?(&1, m) end))
    )
    |> Enum.take(6)
    |> Enum.map_join(" ", &String.trim/1)
    |> String.slice(0, 300)
  end

  defp compiler_error_line?(line) do
    trimmed = String.trim_leading(line)

    Enum.any?(@compiler_error_markers, &String.starts_with?(trimmed, &1)) or
      String.starts_with?(trimmed, "error:")
  end

  # The generated path is written by the child inside the environment, so it
  # is read through the environment (a host `File.read` would miss and read as
  # clean). An injected `:output_file` is a cassette fixture on the host's disk.
  defp read_output(_env, path, true), do: File.read(path)
  defp read_output(env, path, false), do: Environments.read_file(env, path)

  defp output_exists?(_env, path, true), do: File.exists?(path)
  defp output_exists?(env, path, false), do: Environments.file_exists?(env, path)

  # Machine-wide unique, not per-BEAM: see `CodeMySpec.TempFile`.
  defp create_temp_file_path, do: TempFile.path("compile_diagnostics", ".jsonl")

  # An incremental compile reports only what it recompiled; `force: true`
  # reports every module's diagnostics.
  defp compile_args(opts) do
    if Keyword.get(opts, :force, false),
      do: ["compile", "--return-errors", "--force"],
      else: ["compile", "--return-errors"]
  end
end
