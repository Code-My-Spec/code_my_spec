defmodule CodeMySpec.BddSpecs.Spex do
  @moduledoc """
  Executes Spex BDD specifications via `mix spex` and returns structured results.
  Wraps command execution with JSONL output parsing, capturing scenario pass/fail
  status and step-level failure details.
  """

  require Logger

  alias CodeMySpec.BddSpecs.Spex.{Error, Failure, Step}

  @doc """
  Execute mix spex synchronously and parse results.

  ## Parameters

  - `args` - List of arguments to pass to mix spex (e.g., ["test/spex/login_spex.ex"])
  - `opts` - Keyword list of options:
    - `:project_root` - Project root directory to run tests from (defaults to cwd)
    - `:quiet` - Suppress console output (default: false)
    - `:jsonl_path` - Custom path for JSONL output file (defaults to temp file)

  ## Returns

  `{:ok, failures, exit_code}` - List of parsed failures and exit code
  `{:error, {:parse_error, reason}}` - If JSONL parsing fails

  ## Example

      {:ok, failures, exit_code} = Spex.execute(["test/spex/login_spex.ex"])
      exit_code  # => 0 for success, non-zero for failure
  """
  @spec execute(args :: [String.t()], opts :: keyword()) ::
          {:ok, [Failure.t()], integer()} | {:error, {:parse_error, String.t()}}
  def execute(args, opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    quiet = Keyword.get(opts, :quiet, false)

    caller_provided_file = Keyword.has_key?(opts, :output_file) or Keyword.has_key?(opts, :jsonl_path)

    temp_file =
      Keyword.get(
        opts,
        :output_file,
        Keyword.get(
          opts,
          :jsonl_path,
          Path.join(System.tmp_dir!(), "spex_output_#{System.unique_integer([:positive])}.jsonl")
        )
      )

    spex_args = build_args(args, temp_file, quiet)
    command = "mix " <> Enum.join(spex_args, " ")

    Logger.info("[Spex] Running: #{command}")

    case System.cmd("mix", spex_args, cd: project_root, stderr_to_stdout: true) do
      {_raw_output, exit_code} ->
        result = parse_and_return_failures(temp_file, exit_code)
        unless caller_provided_file, do: cleanup_temp_file(temp_file)
        result
    end
  rescue
    exception ->
      Logger.error("[Spex] Execution error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  @doc """
  Parses JSONL failure file into Failure structs.

  ## Parameters

  - `path` - Path to the JSONL file

  ## Returns

  `{:ok, [Failure.t()]}` - List of parsed failures (empty if file doesn't exist or is empty)
  `{:error, term()}` - If JSON parsing fails
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec parse_jsonl(String.t()) :: {:ok, [Failure.t()]} | {:error, term()}
  def parse_jsonl(path) do
    case File.read(path) do
      {:ok, ""} ->
        {:ok, []}

      {:ok, content} ->
        parse_jsonl_content(content)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp build_args(args, temp_file, quiet) do
    base_args = ["spex" | args] ++ ["--jsonl=#{temp_file}"]

    if quiet do
      base_args ++ ["--quiet"]
    else
      base_args
    end
  end

  defp parse_and_return_failures(temp_file, exit_code) do
    case parse_jsonl(temp_file) do
      {:ok, failures} ->
        {:ok, failures, exit_code}

      {:error, reason} ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_temp_file(temp_file) do
    File.rm(temp_file)
  end

  defp parse_jsonl_content(content) do
    lines =
      content
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 == ""))

    parse_lines(lines, [])
  end

  defp parse_lines([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_lines([line | rest], acc) do
    case Jason.decode(line) do
      {:ok, data} ->
        failure = build_failure(data)
        parse_lines(rest, [failure | acc])

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp build_failure(data) do
    %Failure{
      spex: data["spex"],
      scenario: data["scenario"],
      steps: build_steps(data["steps"] || []),
      error: build_error(data["error"])
    }
  end

  defp build_steps(steps_data) do
    Enum.map(steps_data, fn step ->
      %Step{
        type: step["type"],
        description: step["description"],
        status: step["status"]
      }
    end)
  end

  defp build_error(nil), do: nil

  defp build_error(error_data) do
    %Error{
      message: error_data["message"],
      file: error_data["file"],
      line: error_data["line"],
      stacktrace: error_data["stacktrace"] || [],
      left: error_data["left"],
      right: error_data["right"]
    }
  end
end
