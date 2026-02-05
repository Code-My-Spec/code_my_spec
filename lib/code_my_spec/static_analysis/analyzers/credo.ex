defmodule CodeMySpec.StaticAnalysis.Analyzers.Credo do
  @moduledoc """
  Runs Credo static analysis for code consistency and style checks.

  Executes `mix credo suggest --format json --all --all-priorities`, captures stdout
  to a temporary file for reliable JSON parsing, then converts to Problems. Implements
  the AnalyzerBehaviour to provide pluggable static analysis capabilities with
  consistent error handling and result normalization.
  """

  @behaviour CodeMySpec.StaticAnalysis.AnalyzerBehaviour

  alias CodeMySpec.Problems
  alias CodeMySpec.Users.Scope

  require Logger

  @impl true
  @spec name() :: String.t()
  def name, do: "credo"

  @impl true
  @spec available?(Scope.t()) :: boolean()
  def available?(%Scope{active_project: project}) do
    with false <- is_nil(project),
         false <- is_nil(project.code_repo),
         true <- File.dir?(project.code_repo),
         true <- File.exists?(Path.join(project.code_repo, "mix.exs")),
         true <- File.dir?(Path.join(project.code_repo, "deps/credo")) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  @spec run(Scope.t(), keyword()) :: {:ok, [Problems.Problem.t()]} | {:error, String.t()}
  def run(%Scope{active_project: project} = scope, opts \\ []) do
    with {:ok, code_repo} <- validate_project(project),
         {:ok, temp_file} <- create_temp_file() do
      result = execute_and_parse(code_repo, temp_file, scope, opts)
      cleanup_temp_file(temp_file)
      result
    end
  rescue
    exception ->
      Logger.error("Credo analyzer crashed: #{inspect(exception)}")
      {:error, "Credo analyzer crashed: #{Exception.message(exception)}"}
  end

  # Private functions

  defp validate_project(%{code_repo: nil}), do: {:error, "Project has no code_repo configured"}
  defp validate_project(%{code_repo: code_repo}), do: {:ok, code_repo}
  defp validate_project(nil), do: {:error, "No project in scope"}

  defp create_temp_file do
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    temp_file = Path.join(temp_dir, "credo_output_#{unique_id}.json")
    {:ok, temp_file}
  rescue
    exception ->
      {:error, "Failed to create temporary file: #{Exception.message(exception)}"}
  end

  defp execute_and_parse(code_repo, temp_file, scope, opts) do
    with {:ok, json_output} <- execute_credo(code_repo, temp_file, opts),
         {:ok, issues} <- parse_json_output(json_output),
         problems <- convert_to_problems(issues, scope) do
      {:ok, problems}
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp execute_credo(code_repo, temp_file, opts) do
    args = build_credo_args(opts)

    case System.cmd("mix", args, cd: code_repo, stderr_to_stdout: true) do
      {output, exit_code} when exit_code in 0..127 ->
        # Credo exit codes 0-7: success (0 = no issues, 1-7 = issues based on priority)
        # Exit codes 8-127: reserved but not errors
        # However, if output is empty and exit_code > 1, likely an error (e.g., missing project)
        if exit_code > 1 and String.trim(output) == "" do
          {:error, "Credo failed with exit code #{exit_code} and no output"}
        else
          case File.write(temp_file, output) do
            :ok -> {:ok, output}
            {:error, reason} -> {:error, "Failed to write output: #{inspect(reason)}"}
          end
        end

      {output, exit_code} ->
        # Exit code 128+ indicates signal/crash
        {:error, "Credo failed with exit code #{exit_code}: #{output}"}
    end
  rescue
    exception ->
      {:error, "Failed to execute Credo: #{Exception.message(exception)}"}
  end

  defp build_credo_args(opts) do
    base_args = ["credo", "suggest", "--format", "json", "--all", "--all-priorities", "--no-color"]

    args =
      case Keyword.get(opts, :config_file) do
        nil -> base_args
        config_file -> base_args ++ ["--config-file", config_file]
      end

    # Add specific files if provided
    case Keyword.get(opts, :files) do
      nil -> args
      [] -> args
      files when is_list(files) -> args ++ files
    end
  end

  defp parse_json_output(output) do
    # Extract JSON from output - skip any compilation messages that precede it
    json_output = extract_json_from_output(output)

    case Jason.decode(json_output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        {:ok, issues}

      {:ok, %{}} ->
        # No issues key, return empty list
        {:ok, []}

      {:ok, _other} ->
        {:error, "Unexpected JSON structure from Credo output"}

      {:error, %Jason.DecodeError{} = error} ->
        Logger.warning("Failed to parse Credo JSON: #{Exception.message(error)}")
        Logger.debug("Raw output: #{String.slice(output, 0, 500)}")
        {:ok, []}
    end
  end

  # Extract JSON object from output that may have compilation messages prefixed
  defp extract_json_from_output(output) do
    case :binary.match(output, "{") do
      {start, _} -> binary_part(output, start, byte_size(output) - start)
      :nomatch -> output
    end
  end

  defp convert_to_problems(issues, %Scope{active_project_id: project_id}) do
    Enum.map(issues, fn issue ->
      issue
      |> Problems.from_credo()
      |> Map.put(:project_id, project_id)
    end)
  end

  defp cleanup_temp_file(temp_file) do
    if File.exists?(temp_file) do
      File.rm(temp_file)
    end
  rescue
    _ -> :ok
  end
end
