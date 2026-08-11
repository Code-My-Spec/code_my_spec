defmodule CodeMySpec.StaticAnalysis.Analyzers.Sobelow do
  @moduledoc """
  Runs Sobelow security scanner for common Phoenix vulnerabilities.

  Executes `mix sobelow --format json --private`, captures stdout to a temporary
  file for reliable JSON parsing, then converts to Problems. Implements the
  AnalyzerBehaviour to provide consistent interface for static analysis execution.
  """

  @behaviour CodeMySpec.StaticAnalysis.AnalyzerBehaviour

  alias CodeMySpec.Environments
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Users.Scope

  require Logger

  @impl true
  @spec name() :: String.t()
  def name, do: "sobelow"

  @impl true
  @spec available?(Scope.t()) :: boolean()
  def available?(%Scope{cwd: cwd} = scope) when is_binary(cwd) and cwd != "" do
    # exec_file_exists?, not File.*: this asks whether the tool is installed for
    # the `mix` that would actually run, and on a remote environment that is not
    # this machine's disk. Raw File calls would inspect the wrong host and answer
    # false, which skips the analyzer silently instead of failing.
    env = StaticAnalysis.resolve_environment([], scope, cwd)

    Environments.exec_file_exists?(env, "mix.exs") and
      Environments.exec_file_exists?(env, "deps/sobelow")
  rescue
    _ -> false
  end

  def available?(_scope), do: false

  @impl true
  @spec run(Scope.t(), keyword()) :: {:ok, [Problem.t()]} | {:error, String.t()}
  def run(%Scope{} = scope, opts \\ []) do
    cwd = opts[:cwd] || scope.cwd

    if is_nil(cwd) or cwd == "" do
      {:error, "No working directory available"}
    else
      with {:ok, temp_file} <- create_temp_file(),
           {:ok, json_output} <- execute_sobelow(cwd, temp_file, opts, scope),
           {:ok, findings} <- parse_json_output(json_output),
           problems <- convert_to_problems(findings, scope) do
        cleanup_temp_file(temp_file)
        {:ok, problems}
      else
        {:error, _reason} = error ->
          error
      end
    end
  rescue
    exception ->
      Logger.error("Sobelow analyzer crashed: #{inspect(exception)}")
      {:error, "Sobelow analyzer crashed: #{Exception.message(exception)}"}
  end

  # Private functions

  defp create_temp_file do
    {:ok, CodeMySpec.TempFile.path("sobelow_output", ".json")}
  rescue
    exception ->
      {:error, "Failed to create temporary file: #{Exception.message(exception)}"}
  end

  defp execute_sobelow(code_repo, temp_file, opts, scope) do
    args = build_sobelow_args(opts)
    environment = StaticAnalysis.resolve_environment(opts, scope, code_repo)

    # `cd:` stays explicit — opts may carry a :cwd override distinct from the
    # environment's root. clean_otp_env is applied by the environment
    # (see Local.cmd/4).
    cmd_opts = [
      cd: code_repo,
      stderr_to_stdout: true
    ]

    # Note: System.cmd in Elixir 1.19 doesn't support :timeout option directly
    # It will timeout after a default period. For custom timeouts, use Port or Task
    # For now, we'll just ignore the timeout option in System.cmd
    # but log it if provided for debugging
    if Keyword.has_key?(opts, :timeout) do
      Logger.debug(
        "Timeout option provided but not used: #{inspect(Keyword.get(opts, :timeout))}"
      )
    end

    case CodeMySpec.Environments.cmd(environment, "mix", args, cmd_opts) do
      {output, exit_code} when exit_code in [0, 1] ->
        # Sobelow exit codes: 0 = no issues, 1 = issues found
        # We write stdout to temp file for reliable parsing
        case File.write(temp_file, output) do
          :ok ->
            {:ok, output}

          {:error, reason} ->
            {:error, "Failed to write output to temp file: #{inspect(reason)}"}
        end

      {output, _exit_code} ->
        cleanup_temp_file(temp_file)
        {:error, "Sobelow command failed: #{output}"}
    end
  rescue
    exception ->
      cleanup_temp_file(temp_file)
      {:error, "Failed to execute Sobelow: #{Exception.message(exception)}"}
  end

  defp build_sobelow_args(_opts) do
    ["sobelow", "--format", "json", "--private"]
  end

  # Output this could not read is not a clean sweep.
  #
  # The same defect `Analyzers.Credo.parse_json_output/1` and
  # `CredoRun.parse/1` were both fixed away from, and their comments already
  # say why: an empty finding list is a clean sweep, a `:full` reconcile
  # against one deletes every Problem the source has, and a broken analyzer
  # therefore becomes indistinguishable from a codebase with nothing wrong
  # with it.
  #
  # It is reachable here the same way. `mix` refuses on a lock mismatch — the
  # state a rebase leaves between a new `mix.lock` and the next `deps.get` —
  # with exit **1** and a plain-text explanation, and exit 1 is sobelow's own
  # "issues found" code, so the refusal lands in the parser rather than in the
  # error branch above. Measured: `Unchecked dependencies for environment
  # test: …`, exit 1.
  #
  # Empty output counts too. `--format json` emits `{"findings": …}` on a real
  # run whether or not it found anything, so nothing to read means it never
  # ran — the same reasoning `CredoRun` uses for exit > 1 with no output.
  @doc false
  # Public so the "could not read" branches can be asserted without a sobelow
  # run — the same reason `CredoRun.reproduce_command/0` is. Nothing downstream
  # fails if one of them regresses to `{:ok, []}`; it just quietly reports a
  # clean sweep.
  def parse_output_for_test(output), do: parse_json_output(output)

  defp parse_json_output(output) do
    output = String.trim(output)

    if output == "" do
      {:error, "sobelow produced no output; it likely never ran"}
    else
      # Extract JSON from output (may have compilation messages before it)
      json_output = extract_json(output)

      case Jason.decode(json_output) do
        {:ok, %{"findings" => findings}} when is_map(findings) ->
          # Sobelow returns findings grouped by confidence level
          all_findings =
            Map.get(findings, "high_confidence", []) ++
              Map.get(findings, "medium_confidence", []) ++
              Map.get(findings, "low_confidence", [])

          {:ok, all_findings}

        {:ok, %{"findings" => findings}} when is_list(findings) ->
          {:ok, findings}

        {:ok, %{}} ->
          # A JSON object with no `findings` key really is a clean sweep — the
          # document parsed and said nothing was found. Distinct from the two
          # below, which are "this is not sobelow's output at all".
          {:ok, []}

        {:ok, _other} ->
          {:error, "unexpected JSON structure from sobelow"}

        {:error, %Jason.DecodeError{} = error} ->
          # The excerpt travels with the error because the reason is almost
          # always in it — a mix refusal, a compile error, a stray log line.
          Logger.warning(
            "[Sobelow] output is not JSON: " <>
              (output |> String.trim() |> String.slice(0, 200))
          )

          {:error,
           "sobelow produced output that is not JSON (#{Exception.message(error)}): " <>
             (output |> String.trim() |> String.slice(0, 300))}
      end
    end
  end

  defp extract_json(output) do
    # Find the JSON object by looking for the sobelow-specific pattern.
    # Sobelow's JSON output starts with `{"findings":` (or `{\n  "findings"` if
    # pretty-printed). Compilation output may contain `{` characters, so we
    # anchor to one of those two start markers.
    case extract_at_marker(output, "{\"findings\"") do
      :nomatch -> extract_at_marker(output, "{\n") |> json_or_default(output)
      potential_json -> trim_to_last_brace(potential_json)
    end
  end

  defp extract_at_marker(output, marker) do
    case :binary.match(output, marker) do
      {start, _} -> binary_part(output, start, byte_size(output) - start)
      :nomatch -> :nomatch
    end
  end

  defp json_or_default(:nomatch, output), do: output
  defp json_or_default(potential_json, _output), do: trim_to_last_brace(potential_json)

  defp trim_to_last_brace(potential_json) do
    case find_last_brace(potential_json) do
      nil -> potential_json
      end_pos -> binary_part(potential_json, 0, end_pos + 1)
    end
  end

  defp find_last_brace(str) do
    str
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.filter(fn {char, _} -> char == "}" end)
    |> List.last()
    |> case do
      nil -> nil
      {_, idx} -> idx
    end
  end

  defp convert_to_problems(findings, %Scope{active_project_id: project_id}) do
    Enum.map(findings, fn finding ->
      %Problem{
        severity: map_sobelow_severity(finding["severity"]),
        source: "sobelow",
        source_type: :static_analysis,
        file_path: finding["file"] || "unknown",
        line: finding["line"],
        message: build_message(finding),
        category: "security",
        rule: finding["type"],
        metadata: finding,
        project_id: project_id
      }
    end)
  end

  defp build_message(finding) do
    type = finding["type"] || "Security vulnerability detected"

    if finding["pipeline"] do
      "#{type} (pipeline: #{finding["pipeline"]})"
    else
      type
    end
  end

  defp map_sobelow_severity("high"), do: :error
  defp map_sobelow_severity("medium"), do: :warning
  defp map_sobelow_severity("low"), do: :info
  defp map_sobelow_severity(_), do: :warning

  defp cleanup_temp_file(temp_file) do
    if File.exists?(temp_file) do
      File.rm(temp_file)
    end
  rescue
    _ -> :ok
  end
end
