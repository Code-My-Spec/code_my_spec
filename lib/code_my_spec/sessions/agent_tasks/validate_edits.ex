defmodule CodeMySpec.Sessions.AgentTasks.ValidateEdits do
  @moduledoc """
  Claude Code stop hook handler that validates files written or edited during an agent session.

  Validates:
  - Spec files (.spec.md) - ensures they conform to the expected schema
  - Code/test files (.ex/.exs) - runs Credo static analysis to catch style and consistency issues
  - Runs tests for edited code files (maps lib/foo.ex to test/foo_test.exs) and test files

  Returns problems to the LLM for correction when validation fails or tests fail.
  """

  require Logger

  alias CodeMySpec.Documents
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.Tests
  alias CodeMySpec.Tests.TestRun

  @doc """
  Validate files edited during a session.

  Retrieves edited files from FileEdits (tracked by TrackEdits hook during PostToolUse)
  and validates:
  - Spec files (.spec.md) against their expected schema
  - Code/test files (.ex/.exs) using Credo static analysis
  - Runs tests for edited code and test files
  """
  @spec run(String.t(), keyword()) :: {:ok, :valid} | {:error, [String.t()]}
  def run(session_id, opts \\ []) do
    working_dir = Keyword.get(opts, :working_dir)
    Logger.info("[ValidateEdits] Starting validation for session: #{session_id}")

    if working_dir do
      Logger.info("[ValidateEdits] Working directory: #{working_dir}")
    end

    all_files = FileEdits.get_edited_files(session_id)
    Logger.info("[ValidateEdits] All edited files: #{inspect(all_files)}")

    spec_files = Enum.filter(all_files, &spec_file?/1)
    code_files = Enum.filter(all_files, &elixir_file?/1)
    Logger.info("[ValidateEdits] Spec files to validate: #{inspect(spec_files)}")
    Logger.info("[ValidateEdits] Code files to check with Credo: #{inspect(code_files)}")

    spec_errors = get_spec_errors(spec_files)
    credo_problems = get_credo_problems(code_files, working_dir)
    test_problems = get_test_problems(code_files, working_dir)

    all_errors =
      spec_errors ++
        format_credo_problems(credo_problems) ++
        format_test_problems(test_problems)

    Logger.info("[ValidateEdits] Total errors: #{length(all_errors)}")

    case all_errors do
      [] -> {:ok, :valid}
      errors -> {:error, errors}
    end
  end

  defp validate_with_path(path) do
    Logger.info("[ValidateEdits] Validating spec file: #{path}")

    case validate_spec_file(path) do
      :ok ->
        Logger.info("[ValidateEdits] File valid: #{path}")
        :ok

      {:error, reason} ->
        Logger.error("[ValidateEdits] File invalid: #{path} - #{reason}")
        {:error, path, reason}
    end
  end

  @spec validate_spec_file(Path.t()) :: :ok | {:error, String.t()}
  def validate_spec_file(file_path) do
    with {:ok, content} <- read_file(file_path),
         :ok <- validate_not_empty(content),
         doc_type <- document_type_from_path(file_path),
         {:ok, _doc} <- Documents.create_dynamic_document(content, doc_type) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found"}
      {:error, reason} -> {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp validate_not_empty(""), do: {:error, "File is empty"}
  defp validate_not_empty(_content), do: :ok

  @spec document_type_from_path(Path.t()) :: String.t()
  def document_type_from_path(file_path) do
    # Pattern: docs/spec/<project>/<context>.spec.md -> context_spec
    # Pattern: docs/spec/<project>/<context>/<component>.spec.md -> spec
    # Pattern: docs/spec/<file>.spec.md -> spec (no project nesting)
    # Pattern: anything else -> spec

    case extract_segments_after_docs_spec(file_path) do
      # docs/spec/<project>/<context>.spec.md - exactly 2 segments
      [_project_dir, _file] -> "context_spec"
      # Everything else is a component spec
      _ -> "spec"
    end
  end

  defp extract_segments_after_docs_spec(file_path) do
    parts = Path.split(file_path)

    case Enum.find_index(parts, &(&1 == "spec")) do
      nil ->
        # No "spec" directory found, return all parts
        parts

      index ->
        # Check if preceding part is "docs"
        if index > 0 and Enum.at(parts, index - 1) == "docs" do
          # Return everything after "docs/spec"
          Enum.drop(parts, index + 1)
        else
          # "spec" exists but not preceded by "docs"
          parts
        end
    end
  end

  @spec spec_file?(Path.t()) :: boolean()
  def spec_file?(file_path) do
    String.ends_with?(file_path, ".spec.md")
  end

  @spec elixir_file?(Path.t()) :: boolean()
  def elixir_file?(file_path) do
    (String.ends_with?(file_path, ".ex") or String.ends_with?(file_path, ".exs")) and
      not spex_file?(file_path)
  end

  @spec spex_file?(Path.t()) :: boolean()
  def spex_file?(file_path) do
    String.ends_with?(file_path, "_spex.exs")
  end

  # Extract spec validation errors as a list of strings
  defp get_spec_errors([]), do: []

  defp get_spec_errors(spec_paths) do
    spec_paths
    |> Enum.map(&validate_with_path/1)
    |> Enum.reject(&(&1 == :ok))
    |> Enum.map(fn {:error, path, reason} -> "#{path}: #{reason}" end)
  end

  # Run Credo on specific files and return Problem structs
  defp get_credo_problems([], _working_dir), do: []

  defp get_credo_problems(file_paths, working_dir) do
    Logger.info("[ValidateEdits] Running Credo on #{length(file_paths)} files")

    # Use provided working_dir or determine project root from the first file path
    cwd = working_dir || find_project_root(hd(file_paths))

    case cwd do
      nil ->
        Logger.warning("[ValidateEdits] Could not determine project root, skipping Credo")
        []

      project_root ->
        run_credo_on_files(file_paths, project_root)
    end
  end

  defp find_project_root(file_path) do
    # Walk up the directory tree to find mix.exs
    file_path
    |> Path.dirname()
    |> find_mix_exs_dir()
  end

  defp find_mix_exs_dir("/"), do: nil
  defp find_mix_exs_dir(""), do: nil

  defp find_mix_exs_dir(dir) do
    if File.exists?(Path.join(dir, "mix.exs")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        nil
      else
        find_mix_exs_dir(parent)
      end
    end
  end

  defp run_credo_on_files(file_paths, project_root) do
    # Check if Credo is available
    credo_dir = Path.join(project_root, "deps/credo")

    if File.dir?(credo_dir) do
      execute_credo(file_paths, project_root)
    else
      Logger.info("[ValidateEdits] Credo not installed, skipping static analysis")
      []
    end
  end

  defp execute_credo(file_paths, project_root) do
    # Build credo command with specific files
    args = ["credo", "suggest", "--format", "json", "--all-priorities" | file_paths]
    Logger.info("[ValidateEdits] Running: mix #{Enum.join(args, " ")}")

    case System.cmd("mix", args, cd: project_root, stderr_to_stdout: true) do
      {output, exit_code} when exit_code <= 128 ->
        parse_credo_output(output)

      {output, exit_code} ->
        Logger.error("[ValidateEdits] Credo failed with exit code #{exit_code}: #{output}")
        []
    end
  rescue
    exception ->
      Logger.error("[ValidateEdits] Credo execution error: #{Exception.message(exception)}")
      []
  end

  defp parse_credo_output(output) do
    case Jason.decode(output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        Enum.map(issues, &Problems.from_credo/1)

      {:ok, %{}} ->
        []

      {:error, %Jason.DecodeError{} = error} ->
        Logger.error("[ValidateEdits] Failed to parse Credo JSON: #{Exception.message(error)}")
        []
    end
  end

  # Format Problem structs into a single feedback string using the renderer
  defp format_credo_problems([]), do: []

  defp format_credo_problems(problems) do
    feedback =
      ProblemRenderer.render_for_feedback(problems,
        context: "Credo static analysis found issues in edited files:",
        max_problems: 20
      )

    [feedback]
  end

  # ============================================================================
  # Test Runner
  # ============================================================================

  # Run tests for edited code/test files and return Problem structs for failures
  defp get_test_problems([], _working_dir), do: []

  defp get_test_problems(file_paths, working_dir) do
    Logger.info("[ValidateEdits] Finding tests for #{length(file_paths)} files")

    # Use provided working_dir or determine project root from the first file
    project_root = working_dir || find_project_root(hd(file_paths))

    case project_root do
      nil ->
        Logger.warning("[ValidateEdits] Could not determine project root, skipping tests")
        []

      root ->
        # Map files to their corresponding test files
        test_files =
          file_paths
          |> Enum.flat_map(&find_test_files(&1, root))
          |> Enum.uniq()
          |> Enum.filter(&File.exists?/1)

        Logger.info("[ValidateEdits] Test files to run: #{inspect(test_files)}")

        case test_files do
          [] ->
            Logger.info("[ValidateEdits] No test files found, skipping tests")
            []

          files ->
            run_tests(files, root)
        end
    end
  end

  # Find test files for a given source file
  defp find_test_files(file_path, project_root) do
    cond do
      # If it's already a test file, use it directly
      test_file?(file_path) ->
        [file_path]

      # If it's a lib file, map to corresponding test file
      lib_file?(file_path) ->
        [map_lib_to_test(file_path, project_root)]

      # Other files (config, etc.) - no tests
      true ->
        []
    end
  end

  @spec test_file?(Path.t()) :: boolean()
  def test_file?(file_path) do
    String.ends_with?(file_path, "_test.exs") or String.contains?(file_path, "/test/")
  end

  defp lib_file?(file_path) do
    String.contains?(file_path, "/lib/") and String.ends_with?(file_path, ".ex")
  end

  # Map lib/foo/bar.ex to test/foo/bar_test.exs
  defp map_lib_to_test(lib_path, project_root) do
    # Extract the path relative to lib/
    relative =
      lib_path
      |> String.replace(~r{.*/lib/}, "")
      |> String.replace_suffix(".ex", "_test.exs")

    Path.join([project_root, "test", relative])
  end

  defp run_tests(test_files, project_root) do
    Logger.info("[ValidateEdits] Running #{length(test_files)} test files")

    case Tests.execute(test_files, project_root: project_root) do
      {:ok, %TestRun{failures: failures}} when failures != [] ->
        Logger.info("[ValidateEdits] Found #{length(failures)} test failures")
        convert_failures_to_problems(failures)

      {:ok, %TestRun{execution_status: :error} = test_run} ->
        Logger.error("[ValidateEdits] Test execution error: #{test_run.raw_output}")

        [
          %Problems.Problem{
            severity: :error,
            source: "exunit",
            source_type: :test,
            file_path: hd(test_files),
            message: "Test execution failed. Check compilation errors.",
            category: "test_error"
          }
        ]

      {:ok, _test_run} ->
        Logger.info("[ValidateEdits] All tests passed")
        []

      {:error, reason} ->
        Logger.error("[ValidateEdits] Test execution failed: #{inspect(reason)}")
        []
    end
  end

  defp convert_failures_to_problems(failures) do
    Enum.flat_map(failures, fn failure ->
      case failure.error do
        nil ->
          []

        error ->
          [Problems.from_test_failure(error)]
      end
    end)
  end

  # Format test Problem structs into a single feedback string
  defp format_test_problems([]), do: []

  defp format_test_problems(problems) do
    feedback =
      ProblemRenderer.render_for_feedback(problems,
        context: "Tests failed for edited files:",
        max_problems: 10
      )

    [feedback]
  end

  @spec format_output({:ok, :valid} | {:error, [String.t()]}) :: map()
  def format_output({:ok, :valid}) do
    %{}
  end

  # File not found means nothing to validate - allow rather than block
  def format_output({:error, [:file_not_found]}) do
    %{}
  end

  def format_output({:error, errors}) when is_list(errors) do
    reason =
      case errors do
        [single] -> single
        multiple -> "Validation errors:\n" <> Enum.map_join(multiple, "\n", &"- #{&1}")
      end

    %{"decision" => "block", "reason" => reason}
  end
end
