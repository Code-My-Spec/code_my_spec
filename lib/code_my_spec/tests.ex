defmodule CodeMySpec.Tests do
  @moduledoc """
  Tests context for executing and parsing ExUnit test results.
  Provides a clean functional interface for test execution and result analysis.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.ExecutionContexts, CodeMySpec.TempFile],
    exports: :all

  require Logger

  alias CodeMySpec.ExecutionContexts

  alias CodeMySpec.Tests.TestRun

  @doc """
  Execute mix test synchronously and parse results.

  ## Parameters

  - `args` - List of arguments to pass to mix test (e.g., ["test/my_test.exs", "--only", "integration"])
  - `opts` - Keyword list of options:
    - `:execution_context` - Environment to run tests in (required); commands run in its cwd
    - `:output_file` - Path for test results JSON (optional, defaults to temp file)

  ## Returns

  `{:ok, %TestRun{}}` - Parsed test run with stats, failures, etc.
  `{:error, {:parse_error, raw_output}}` - If JSON parsing fails

  ## Example

      {:ok, test_run} = Tests.execute(["test/my_test.exs"], execution_context: env)
      test_run.stats.failures  # => 0
  """
  @spec execute(args :: [String.t()], opts :: keyword()) ::
          {:ok, TestRun.t()} | {:error, {:parse_error, String.t()}}
  def execute(args, opts \\ []) do
    env = Keyword.fetch!(opts, :execution_context)

    temp_file =
      Keyword.get_lazy(opts, :output_file, fn ->
        CodeMySpec.TempFile.path("test_output", ".json")
      end)

    test_args = ["test", "--formatter", "ClientUtils.TestFormatter" | args]
    # The project's `test` recipe when it declares one; the arguments are the same.
    program = if ExecutionContexts.recipe?(env, "test"), do: "just", else: "mix"
    command = program <> " " <> Enum.join(test_args, " ")
    file_path = extract_file_path(args)

    extra_env = Keyword.get(opts, :extra_env, [])

    # `merge_clean_env/1` scrubs the release's OTP variables while keeping these
    # explicit ones; `++ clean_otp_env()` would unset MIX_ENV.
    cmd_env =
      ExecutionContexts.merge_clean_env(
        env:
          [{"MIX_ENV", "test"}, {"EXUNIT_JSON_OUTPUT_FILE", temp_file}] ++
            partition_env(env, extra_env) ++ extra_env
      )[:env]

    Logger.info("[Tests] Running: #{command}")

    # Track whether we're using a caller-provided file (cache) vs a generated temp file
    caller_provided_file = Keyword.has_key?(opts, :output_file)

    case run_with_database(env, program, test_args, cmd_env) do
      {raw_output, exit_code} ->
        json_content = read_test_results(env, temp_file, caller_provided_file)

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

  # The analyzer gets its own test database, never the agent's. A caller that
  # already set `MIX_TEST_PARTITION` (the harness) wins; otherwise one is
  # derived per working copy.
  # See knowledge/analysis, "Test databases".
  defp partition_env(env, extra_env) do
    if List.keymember?(extra_env, "MIX_TEST_PARTITION", 0),
      do: [],
      else: [{"MIX_TEST_PARTITION", partition(env)}]
  end

  # One per working copy, reused (not per run: that would mean creating one on
  # every stop). Never a constant: `config/test.exs` uses the partition instead
  # of its per-worktree name, so a constant is shared by every worktree.
  @analyzer_partition "_analyzer"

  defp partition(%{cwd: cwd}) when is_binary(cwd) and cwd != "",
    do: "_" <> Path.basename(cwd) <> @analyzer_partition

  defp partition(_env) do
    case System.get_env("MIX_TEST_PARTITION") do
      value when is_binary(value) and value != "" -> value <> @analyzer_partition
      _ -> @analyzer_partition
    end
  end

  # Never creates or migrates a database: nothing here migrates from code. A
  # missing database surfaces as the child's own "database does not exist".
  # See knowledge/analysis, "Test databases".
  defp run_with_database(env, program, test_args, cmd_env) do
    ExecutionContexts.cmd(env, program, test_args, stderr_to_stdout: true, env: cmd_env)
  end

  # The generated path is written inside the environment, so it is read (and
  # deleted) through it; a host-side miss would parse "{}" as a clean suite. A
  # caller-provided path is a host-local cassette fixture, not ours to delete.
  defp read_test_results(env, temp_file, caller_provided_file) do
    read =
      if caller_provided_file,
        do: File.read(temp_file),
        else: ExecutionContexts.read_file(env, temp_file)

    result =
      case read do
        {:ok, content} ->
          content

        {:error, reason} ->
          Logger.warning("Failed to read test results file #{temp_file}: #{inspect(reason)}")
          "{}"
      end

    unless caller_provided_file, do: ExecutionContexts.delete_file(env, temp_file)
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
