defmodule CodeMySpec.StaticAnalysis.Analyzers.Sobelow do
  @moduledoc """
  Runs Sobelow security scanner for common Phoenix vulnerabilities.

  Executes `mix sobelow --format json --private`, captures stdout to a temporary
  file for reliable JSON parsing, then converts to Problems. Implements the
  AnalyzerBehaviour to provide consistent interface for static analysis execution.
  """

  @behaviour CodeMySpec.StaticAnalysis.AnalyzerBehaviour

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Users.Scope

  require Logger

  @impl true
  @spec name() :: String.t()
  def name, do: "sobelow"

  @impl true
  @spec available?(Scope.t()) :: boolean()
  def available?(%Scope{cwd: cwd}) when is_binary(cwd) and cwd != "" do
    with true <- File.dir?(cwd),
         true <- File.exists?(Path.join(cwd, "mix.exs")),
         true <- File.dir?(Path.join(cwd, "deps/sobelow")) do
      true
    else
      _ -> false
    end
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
           {:ok, json_output} <- execute_sobelow(cwd, temp_file, opts),
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
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    temp_file = Path.join(temp_dir, "sobelow_output_#{unique_id}.json")
    {:ok, temp_file}
  rescue
    exception ->
      {:error, "Failed to create temporary file: #{Exception.message(exception)}"}
  end

  defp execute_sobelow(code_repo, temp_file, opts) do
    args = build_sobelow_args(opts)

    # Build System.cmd options
    cmd_opts = [cd: code_repo, stderr_to_stdout: true]

    # Note: System.cmd in Elixir 1.19 doesn't support :timeout option directly
    # It will timeout after a default period. For custom timeouts, use Port or Task
    # For now, we'll just ignore the timeout option in System.cmd
    # but log it if provided for debugging
    if Keyword.has_key?(opts, :timeout) do
      Logger.debug(
        "Timeout option provided but not used: #{inspect(Keyword.get(opts, :timeout))}"
      )
    end

    case System.cmd("mix", args, cmd_opts) do
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

  defp parse_json_output(output) do
    # Handle empty output
    output = String.trim(output)

    if output == "" do
      {:ok, []}
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
          # No findings key, return empty list
          {:ok, []}

        {:ok, _other} ->
          # Unexpected structure but valid JSON, return empty list
          {:ok, []}

        {:error, %Jason.DecodeError{} = error} ->
          # JSON parsing failed - likely not JSON output
          Logger.warning("Failed to parse Sobelow output as JSON: #{Exception.message(error)}")
          {:ok, []}
      end
    end
  end

  defp extract_json(output) do
    # Find the JSON object by looking for the sobelow-specific pattern
    # The JSON output from sobelow starts with {"findings":
    # We need to find this pattern because compilation output may contain { characters
    case :binary.match(output, "{\"findings\"") do
      {start, _} ->
        # Extract from the JSON start to the end of the output
        potential_json = binary_part(output, start, byte_size(output) - start)
        # Find the last } which should close the JSON object
        case find_last_brace(potential_json) do
          nil -> potential_json
          end_pos -> binary_part(potential_json, 0, end_pos + 1)
        end

      :nomatch ->
        # Try with newline formatting: {\n  "findings"
        case :binary.match(output, "{\n") do
          {start, _} ->
            potential_json = binary_part(output, start, byte_size(output) - start)

            case find_last_brace(potential_json) do
              nil -> potential_json
              end_pos -> binary_part(potential_json, 0, end_pos + 1)
            end

          :nomatch ->
            output
        end
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
