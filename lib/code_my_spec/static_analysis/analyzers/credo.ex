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
  def available?(%Scope{cwd: cwd}) when is_binary(cwd) and cwd != "" do
    with true <- File.dir?(cwd),
         true <- File.exists?(Path.join(cwd, "mix.exs")),
         true <- File.dir?(Path.join(cwd, "deps/credo")) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def available?(_scope), do: false

  @impl true
  @spec run(Scope.t(), keyword()) :: {:ok, [Problems.Problem.t()]} | {:error, String.t()}
  def run(%Scope{} = scope, opts \\ []) do
    cwd = opts[:cwd] || scope.cwd

    cond do
      is_nil(cwd) or cwd == "" ->
        {:error, "No working directory available"}

      opts[:output_file] ->
        # Spex-only escape hatch — read pre-recorded JSON instead of
        # running `mix credo`. Used by cassette-backed tests that
        # exercise the credo block path without losing the race against
        # FileWatcherServer (see issue 7d956b03). The file is expected
        # to be in the same JSON shape `mix credo --format json` would
        # produce.
        read_from_output_file(opts[:output_file], scope)

      true ->
        with {:ok, temp_file} <- create_temp_file() do
          result = execute_and_parse(cwd, temp_file, scope, opts)
          cleanup_temp_file(temp_file)
          result
        end
    end
  rescue
    exception ->
      Logger.error("Credo analyzer crashed: #{inspect(exception)}")
      {:error, "Credo analyzer crashed: #{Exception.message(exception)}"}
  end

  defp read_from_output_file(path, scope) do
    with {:ok, raw} <- File.read(path),
         {:ok, issues} <- parse_json_output(raw) do
      {:ok, convert_to_problems(issues, scope)}
    else
      {:error, %File.Error{} = err} ->
        {:error, "Failed to read credo output file #{path}: #{Exception.message(err)}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "Failed to read credo output file #{path}: #{reason}"}

      {:error, reason} ->
        {:error, "Failed to parse credo output file #{path}: #{inspect(reason)}"}
    end
  end

  # Private functions

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
    args = build_credo_args(opts, code_repo)

    case System.cmd("mix", args, cd: code_repo, stderr_to_stdout: true) do
      {output, exit_code} when exit_code in 0..127 ->
        handle_credo_output(output, exit_code, temp_file)

      {output, exit_code} ->
        {:error, "Credo failed with exit code #{exit_code}: #{output}"}
    end
  rescue
    exception ->
      {:error, "Failed to execute Credo: #{Exception.message(exception)}"}
  end

  defp handle_credo_output(output, exit_code, temp_file) when exit_code > 1 do
    if String.trim(output) == "" do
      {:error, "Credo failed with exit code #{exit_code} and no output"}
    else
      write_and_return(temp_file, output)
    end
  end

  defp handle_credo_output(output, _exit_code, temp_file) do
    write_and_return(temp_file, output)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_and_return(temp_file, output) do
    case File.write(temp_file, output) do
      :ok -> {:ok, output}
      {:error, reason} -> {:error, "Failed to write output: #{inspect(reason)}"}
    end
  end

  defp build_credo_args(opts, cwd) do
    base_args = [
      "credo",
      "suggest",
      "--format",
      "json",
      "--all",
      "--all-priorities",
      "--no-color"
    ]

    args =
      case Keyword.get(opts, :config_file) do
        nil -> base_args
        config_file -> base_args ++ ["--config-file", config_file]
      end

    # Add specific files if provided, made relative to cwd so Credo resolves them correctly
    case Keyword.get(opts, :files) do
      nil -> args
      [] -> args
      files when is_list(files) -> args ++ make_relative(files, cwd)
    end
  end

  defp make_relative(files, cwd) do
    abs_cwd = Path.expand(cwd)

    Enum.map(files, fn file ->
      abs_file = Path.expand(file)

      case Path.relative_to(abs_file, abs_cwd) do
        ^abs_file -> file
        relative -> relative
      end
    end)
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

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_temp_file(temp_file) do
    tmp_dir = System.tmp_dir!()

    if String.starts_with?(Path.expand(temp_file), tmp_dir) and File.exists?(temp_file) do
      File.rm(temp_file)
    end
  rescue
    _ -> :ok
  end
end
