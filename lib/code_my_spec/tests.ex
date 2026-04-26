defmodule CodeMySpec.Tests do
  @moduledoc """
  Tests context for executing and parsing ExUnit test results.
  Provides a clean functional interface for test execution and result analysis.
  """

  require Logger

  alias CodeMySpec.Tests.TestRun

  @doc """
  Execute mix test synchronously and parse results.

  ## Parameters

  - `args` - List of arguments to pass to mix test (e.g., ["test/my_test.exs", "--only", "integration"])
  - `opts` - Keyword list of options:
    - `:project_root` - Project root directory to run tests from (defaults to cwd)
    - `:output_file` - Path for test results JSON (optional, defaults to temp file)

  ## Returns

  `{:ok, %TestRun{}}` - Parsed test run with stats, failures, etc.
  `{:error, {:parse_error, raw_output}}` - If JSON parsing fails

  ## Example

      {:ok, test_run} = Tests.execute(["test/my_test.exs"])
      test_run.stats.failures  # => 0
  """
  @spec execute(args :: [String.t()], opts :: keyword()) ::
          {:ok, TestRun.t()} | {:error, {:parse_error, String.t()}}
  def execute(args, opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    temp_file =
      Keyword.get_lazy(opts, :output_file, fn ->
        Path.join(System.tmp_dir!(), "test_output_#{System.unique_integer([:positive])}.json")
      end)

    test_args = ["test", "--formatter", "ClientUtils.TestFormatter" | args]
    command = "mix " <> Enum.join(test_args, " ")
    file_path = extract_file_path(args)

    env = [
      {"MIX_ENV", "test"},
      {"EXUNIT_JSON_OUTPUT_FILE", temp_file}
    ]

    Logger.info("[Tests] Running: #{command}")

    # Track whether we're using a caller-provided file (cache) vs a generated temp file
    caller_provided_file = Keyword.has_key?(opts, :output_file)

    case System.cmd("mix", test_args, cd: project_root, stderr_to_stdout: true, env: env) do
      {raw_output, exit_code} ->
        json_content = read_test_results(temp_file, caller_provided_file)

        parse_test_results(json_content, %{
          file_path: file_path,
          command: command,
          exit_code: exit_code,
          raw_output: raw_output,
          ran_at: DateTime.utc_now()
        })
    end
  rescue
    exception ->
      Logger.error("[Tests] Execution error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  defp read_test_results(temp_file, caller_provided_file) do
    result =
      case File.read(temp_file) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Logger.warning("Failed to read test results file #{temp_file}: #{inspect(reason)}")
          "{}"
      end

    unless caller_provided_file, do: File.rm(temp_file)
    result
  end

  defp extract_file_path(args) do
    Enum.find(args, "unknown", fn arg ->
      String.contains?(arg, "/") or String.ends_with?(arg, ".exs") or
        String.ends_with?(arg, ".ex")
    end)
  end

  defp parse_test_results(json_string, metadata) do
    case Jason.decode(json_string) do
      {:ok, data} ->
        build_test_run(data, metadata)

      {:error, _} ->
        {:error, {:parse_error, json_string}}
    end
  end

  defp build_test_run(data, metadata) do
    execution_status = determine_execution_status(data, metadata.exit_code)

    attrs =
      data
      |> Map.merge(%{
        "file_path" => metadata.file_path,
        "command" => metadata.command,
        "exit_code" => metadata.exit_code,
        "execution_status" => execution_status,
        "raw_output" => metadata.raw_output,
        "ran_at" => metadata.ran_at
      })

    changeset = TestRun.parse_changeset(%TestRun{}, attrs)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      errors =
        Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
          "#{field}: #{message}"
        end)

      Logger.warning("Failed to build TestRun: #{errors}")
      {:error, {:parse_error, "Invalid test run data: #{errors}"}}
    end
  end

  defp determine_execution_status(data, exit_code) do
    cond do
      exit_code == 0 -> :success
      get_in(data, ["stats", "failures"]) && get_in(data, ["stats", "failures"]) > 0 -> :failure
      exit_code != nil && exit_code != 0 -> :error
      true -> :error
    end
  end
end
