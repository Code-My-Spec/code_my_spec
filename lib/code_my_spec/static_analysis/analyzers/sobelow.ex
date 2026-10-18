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
  alias CodeMySpec.StaticAnalysis.SobelowRun
  alias CodeMySpec.Users.Scope

  require Logger

  @impl true
  @spec name() :: String.t()
  def name, do: "sobelow"

  @impl true
  @spec available?(Scope.t(), keyword()) :: boolean()
  def available?(%Scope{} = scope, opts \\ []) do
    # exec_file_exists?, not File.*: this asks whether the tool is installed for
    # the `mix` that would actually run, and on a remote environment that is not
    # this machine's disk. Raw File calls would inspect the wrong host and answer
    # false, which skips the analyzer silently instead of failing.
    env = StaticAnalysis.resolve_environment(opts, scope, Keyword.get(opts, :cwd) || scope.cwd)

    not is_nil(env) and Environments.exec_file_exists?(env, "mix.exs") and
      Environments.exec_file_exists?(env, "deps/sobelow")
  end

  @impl true
  @spec run(Scope.t(), keyword()) ::
          {:ok, [Problem.t()]} | {:error, String.t() | :no_environment}
  def run(%Scope{} = scope, opts \\ []) do
    case run_with_output(scope, opts) do
      {:ok, problems, _raw} -> {:ok, problems}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Same as `run/2`, plus the raw JSON `mix sobelow` printed.

  Threads real output end to end the same way `Analyzers.Credo.run_with_output/2`
  does, for the same reason: `Analysis.Runners` bypasses `StaticRunner`'s
  generic `{:ok, [Problem.t()]}` contract to get a raw-output channel, since
  `AnalyzerBehaviour` never had one (`9a78afa1`).
  """
  @spec run_with_output(Scope.t(), keyword()) ::
          {:ok, [Problem.t()], String.t()} | {:error, String.t() | :no_environment}
  def run_with_output(%Scope{} = scope, opts \\ []) do
    environment =
      StaticAnalysis.resolve_environment(opts, scope, Keyword.get(opts, :cwd) || scope.cwd)

    cwd = opts[:cwd] || (environment && environment.cwd)

    cond do
      is_nil(environment) ->
        {:error, :no_environment}

      is_nil(cwd) or cwd == "" ->
        {:error, "No working directory available"}

      opts[:output_file] ->
        read_from_output_file(opts[:output_file], scope)

      true ->
        opts = Keyword.put(opts, :environment, environment)
        temp_file = CodeMySpec.TempFile.path("sobelow_output", ".json")
        result = execute_and_parse(cwd, temp_file, scope, opts)
        CodeMySpec.TempFile.cleanup(temp_file)
        result
    end
  rescue
    exception ->
      Logger.error("Sobelow analyzer crashed: #{inspect(exception)}")
      {:error, "Sobelow analyzer crashed: #{Exception.message(exception)}"}
  end

  defp read_from_output_file(path, scope) do
    with {:ok, raw} <- File.read(path),
         {:ok, findings} <- parse_json_output(raw) do
      {:ok, convert_to_problems(findings, scope), raw}
    else
      {:error, %File.Error{} = err} ->
        {:error, "Failed to read sobelow output file #{path}: #{Exception.message(err)}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "Failed to read sobelow output file #{path}: #{reason}"}

      {:error, reason} ->
        {:error, "Failed to parse sobelow output file #{path}: #{inspect(reason)}"}
    end
  end

  # Private functions

  defp execute_and_parse(cwd, temp_file, scope, opts) do
    with {:ok, json_output} <- execute_sobelow(cwd, temp_file, opts, scope),
         {:ok, findings} <- parse_json_output(json_output),
         problems <- convert_to_problems(findings, scope) do
      {:ok, problems, json_output}
    else
      {:error, _reason} = error ->
        error
    end
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
        {:error, "Sobelow command failed: #{output}"}
    end
  rescue
    exception ->
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
  # run. Nothing downstream
  # fails if one of them regresses to `{:ok, []}`; it just quietly reports a
  # clean sweep.
  def parse_output_for_test(output), do: parse_json_output(output)

  # Extraction lives in `SobelowRun` — one implementation, mirroring the
  # reasoning `Analyzers.Credo`/`CredoRun` already established: slicing from
  # the first or last `{` breaks the moment compilation chatter (which is full
  # of braces) precedes the real document, so this tries each `{` in order and
  # keeps the first that decodes with a `findings` key.
  defp parse_json_output(output) do
    output = String.trim(output)

    if output == "" do
      {:error, "sobelow produced no output; it likely never ran"}
    else
      case SobelowRun.extract_json(output) do
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
          # document parsed and said nothing was found. Distinct from `:error`,
          # which is "this is not sobelow's output at all".
          {:ok, []}

        {:ok, _other} ->
          {:error, "unexpected JSON structure from sobelow"}

        :error ->
          # The excerpt travels with the error because the reason is almost
          # always in it — a mix refusal, a compile error, a stray log line.
          Logger.warning(
            "[Sobelow] no JSON document in sobelow's output: " <> String.slice(output, 0, 200)
          )

          {:error, "sobelow produced output that is not JSON: " <> String.slice(output, 0, 300)}
      end
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
end
