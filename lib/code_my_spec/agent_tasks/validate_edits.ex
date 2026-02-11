defmodule CodeMySpec.AgentTasks.ValidateEdits do
  @moduledoc """
  Claude Code stop hook handler that validates files written or edited during an agent session.

  Validation Pipeline (execution order):
  1. Compile - Compile the project once upfront
  2. Tests - Run tests for modified code files and modified test files
  3. Credo - Run on all modified Elixir files via StaticAnalysis.Runner
  4. Sobelow - Run on all modified Elixir files via StaticAnalysis.Runner
  5. Spex - Run BDD specs for modified spex files
  6. Document validation - Validate .spec.md files against schemas

  Files that pass all validators are removed from FileEdits tracking.
  """

  require Logger

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Documents
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Tests
  alias CodeMySpec.Tests.TestRun
  alias CodeMySpec.Users.Scope

  @doc """
  Execute validation on files edited during a Claude Code session.

  ## Options
  - `:scope` - A Scope struct with active_project (required for static analysis)
  - `:working_dir` - Project root directory (used to build Scope if not provided)
  - `:agent_id` - When provided, only validates files edited by this agent (for SubagentStop).
    When nil, validates all files in the session (for Stop).
  """
  @spec run(String.t(), keyword()) :: {:ok, :valid} | {:error, [Problem.t()]}
  def run(session_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)

    Logger.info(
      "[ValidateEdits] Starting validation for session: #{session_id}, agent: #{agent_id || "all"}, pid: #{inspect(self())}"
    )

    with {:ok, all_files} <- get_files(session_id, opts),
         {:ok, categorized} <- categorize_files(all_files, opts),
         {:ok, scope} <- get_or_build_scope(all_files, opts),
         :ok <- compile_project(scope),
         {:ok, test_problems} <- run_tests(categorized.test_files, scope),
         {:ok, credo_problems} <- run_credo(categorized.elixir_files, scope),
         {:ok, sobelow_problems} <- run_sobelow(categorized.elixir_files, scope),
         {:ok, spex_problems} <- run_spex(categorized.spex_files, scope),
         {:ok, spec_problems} <- validate_spec_files(categorized.spec_files) do
      all_problems =
        test_problems ++ credo_problems ++ sobelow_problems ++ spex_problems ++ spec_problems

      Logger.info(
        "[ValidateEdits] Validation complete: #{length(all_files)} files, " <>
          "#{length(all_problems)} problems " <>
          "(test: #{length(test_problems)}, credo: #{length(credo_problems)}, " <>
          "sobelow: #{length(sobelow_problems)}, spex: #{length(spex_problems)}, " <>
          "spec: #{length(spec_problems)})"
      )

      if all_problems == [] do
        FileEdits.remove_edited_files(session_id, all_files, agent_id)
        {:ok, :valid}
      else
        failed_files = extract_failed_files(all_problems)
        passed_files = all_files -- failed_files
        FileEdits.remove_edited_files(session_id, passed_files, agent_id)
        {:error, all_problems}
      end
    else
      {:empty, :no_files} ->
        Logger.info("[ValidateEdits] No files to validate")
        {:ok, :valid}

      error ->
        error
    end
  end

  # ============================================================================
  # File Retrieval & Categorization
  # ============================================================================

  defp get_files(session_id, opts) do
    case Keyword.get(opts, :files) do
      files when is_list(files) and files != [] ->
        Logger.info("[ValidateEdits] Using #{length(files)} files provided directly")
        {:ok, files}

      _ ->
        agent_id = Keyword.get(opts, :agent_id)
        get_edited_files(session_id, agent_id)
    end
  end

  defp get_edited_files(session_id, nil) do
    files = FileEdits.get_edited_files(session_id)
    Logger.info("[ValidateEdits] Found #{length(files)} edited files for session")

    if files == [] do
      {:empty, :no_files}
    else
      {:ok, files}
    end
  end

  defp get_edited_files(session_id, agent_id) do
    files = FileEdits.get_edited_files_by_agent(session_id, agent_id)
    Logger.info("[ValidateEdits] Found #{length(files)} edited files for agent #{agent_id}")

    if files == [] do
      {:empty, :no_files}
    else
      {:ok, files}
    end
  end

  @doc """
  Categorize files by validator type.
  """
  @spec categorize_files([Path.t()], keyword()) ::
          {:ok,
           %{
             spec_files: [Path.t()],
             test_files: [Path.t()],
             spex_files: [Path.t()],
             code_files: [Path.t()],
             elixir_files: [Path.t()]
           }}
  def categorize_files(files, opts \\ []) do
    spec_files = Enum.filter(files, &spec_file?/1)
    test_files = Enum.filter(files, &test_file?/1)
    spex_files = Enum.filter(files, &spex_file?/1)
    code_files = Enum.filter(files, &code_file?/1)

    # All elixir files for credo/sobelow
    elixir_files = code_files ++ test_files ++ spex_files

    # Map code files to their test files and merge with explicit test files
    project_root = Keyword.get(opts, :working_dir)
    mapped_test_files = map_code_to_test_files(code_files, project_root)
    all_test_files = Enum.uniq(test_files ++ mapped_test_files)

    Logger.info(
      "[ValidateEdits] Categorized - spec: #{length(spec_files)}, test: #{length(all_test_files)}, spex: #{length(spex_files)}, code: #{length(code_files)}, elixir: #{length(elixir_files)}"
    )

    {:ok,
     %{
       spec_files: spec_files,
       test_files: all_test_files,
       spex_files: spex_files,
       code_files: code_files,
       elixir_files: elixir_files
     }}
  end

  @spec spec_file?(Path.t()) :: boolean()
  def spec_file?(path), do: String.ends_with?(path, ".spec.md")

  @spec test_file?(Path.t()) :: boolean()
  def test_file?(path), do: String.ends_with?(path, "_test.exs")

  @spec spex_file?(Path.t()) :: boolean()
  def spex_file?(path), do: String.ends_with?(path, "_spex.exs")

  @spec code_file?(Path.t()) :: boolean()
  def code_file?(path) do
    (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")) and
      not test_file?(path) and not spex_file?(path)
  end

  @doc """
  Map code files to their corresponding test files.
  """
  @spec map_code_to_test_files([Path.t()], Path.t() | nil) :: [Path.t()]
  def map_code_to_test_files(code_files, project_root) do
    code_files
    |> Enum.filter(&lib_file?/1)
    |> Enum.map(&map_lib_to_test(&1, project_root))
    |> Enum.filter(&File.exists?/1)
  end

  defp lib_file?(path), do: String.contains?(path, "/lib/") and String.ends_with?(path, ".ex")

  defp map_lib_to_test(lib_path, project_root) do
    relative =
      lib_path
      |> String.replace(~r{.*/lib/}, "")
      |> String.replace_suffix(".ex", "_test.exs")

    if project_root do
      Path.join([project_root, "test", relative])
    else
      case Regex.run(~r{(.*/?)lib/}, lib_path) do
        [_, root] -> Path.join([root, "test", relative])
        _ -> Path.join(["test", relative])
      end
    end
  end

  # ============================================================================
  # Scope Resolution
  # ============================================================================

  defp get_or_build_scope(_files, opts) do
    case Keyword.get(opts, :scope) do
      %Scope{} = scope -> {:ok, scope}
      nil -> build_scope_from_working_dir(Keyword.get(opts, :working_dir))
    end
  end

  defp build_scope_from_working_dir(nil) do
    Logger.warning(
      "[ValidateEdits] No scope or working_dir provided, static analysis will be skipped"
    )

    {:ok, nil}
  end

  defp build_scope_from_working_dir(working_dir) do
    case Scope.from_local_config(working_dir) do
      {:ok, scope} ->
        {:ok, scope}

      {:error, _} ->
        Logger.warning(
          "[ValidateEdits] Could not build scope from #{working_dir}, skipping static analysis"
        )

        {:ok, nil}
    end
  end

  defp get_project_root(nil), do: nil
  defp get_project_root(%Scope{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd
  defp get_project_root(_scope), do: nil

  # ============================================================================
  # Validators
  # ============================================================================

  @doc """
  Compile the project once before running validators.
  """
  @spec compile_project(Scope.t() | nil) :: :ok | {:error, String.t()}
  def compile_project(nil) do
    Logger.info("[ValidateEdits] No scope, skipping compilation")
    :ok
  end

  def compile_project(%Scope{} = scope) do
    project_root = get_project_root(scope)

    if project_root do
      Logger.info("[ValidateEdits] Compiling project at #{project_root}")

      case CodeMySpec.Compile.execute(cwd: project_root) do
        %{status: :ok} -> :ok
        %{status: :error, exit_code: code} -> {:error, "Compilation failed (exit code #{code})"}
      end
    else
      :ok
    end
  end

  @doc """
  Run tests for modified test files.
  """
  @spec run_tests([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_tests([], _scope) do
    Logger.info("[ValidateEdits] No test files to run")
    {:ok, []}
  end

  def run_tests(test_files, scope) do
    project_root = get_project_root(scope)
    existing_files = Enum.filter(test_files, &File.exists?/1)

    if existing_files == [] do
      Logger.info("[ValidateEdits] No existing test files found")
      {:ok, []}
    else
      Logger.info("[ValidateEdits] Running #{length(existing_files)} test files")

      opts = if project_root, do: [project_root: project_root], else: []

      case Tests.execute(existing_files, opts) do
        {:ok, %TestRun{failures: failures}} when failures != [] ->
          Logger.info("[ValidateEdits] #{length(failures)} test failures")
          {:ok, convert_test_failures(failures)}

        {:ok, %TestRun{execution_status: :error} = run} ->
          Logger.error("[ValidateEdits] Test execution error: #{run.raw_output}")

          {:ok,
           [
             %Problem{
               severity: :error,
               source: "exunit",
               source_type: :test,
               file_path: hd(existing_files),
               message: "Test execution failed. Check compilation errors.",
               category: "test_error"
             }
           ]}

        {:ok, _} ->
          Logger.info("[ValidateEdits] All tests passed")
          {:ok, []}

        {:error, reason} ->
          Logger.error("[ValidateEdits] Test execution failed: #{inspect(reason)}")
          {:ok, []}
      end
    end
  end

  defp convert_test_failures(failures) do
    Enum.flat_map(failures, fn failure ->
      case failure.error do
        nil -> []
        error -> [CodeMySpec.Problems.from_test_failure(error)]
      end
    end)
  end

  @doc """
  Run Credo static analysis on Elixir files via StaticAnalysis.Runner.
  """
  @spec run_credo([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_credo([], _scope) do
    Logger.info("[ValidateEdits] No files for Credo")
    {:ok, []}
  end

  def run_credo(_files, nil) do
    Logger.info("[ValidateEdits] No scope, skipping Credo")
    {:ok, []}
  end

  def run_credo(files, %Scope{} = scope) do
    Logger.info("[ValidateEdits] Running Credo on #{length(files)} files")

    case StaticAnalysis.run(scope, :credo, files: files) do
      {:ok, problems} ->
        # Filter to only problems in edited files
        filtered = filter_problems_by_files(problems, files)
        {:ok, filtered}

      {:error, reason} ->
        Logger.warning("[ValidateEdits] Credo failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  @doc """
  Run Sobelow security analysis via StaticAnalysis.Runner.
  """
  @spec run_sobelow([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_sobelow([], _scope) do
    Logger.info("[ValidateEdits] No files for Sobelow")
    {:ok, []}
  end

  def run_sobelow(_files, nil) do
    Logger.info("[ValidateEdits] No scope, skipping Sobelow")
    {:ok, []}
  end

  def run_sobelow(files, %Scope{} = scope) do
    Logger.info("[ValidateEdits] Running Sobelow")

    case StaticAnalysis.run(scope, :sobelow) do
      {:ok, problems} ->
        # Filter to only problems in edited files
        filtered = filter_problems_by_files(problems, files)
        {:ok, filtered}

      {:error, reason} ->
        Logger.warning("[ValidateEdits] Sobelow failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  @doc """
  Filter problems to only include those affecting specific files.
  """
  @spec filter_problems_by_files([Problem.t()], [Path.t()]) :: [Problem.t()]
  def filter_problems_by_files(problems, files) do
    file_set = MapSet.new(files)
    Enum.filter(problems, &problem_matches_files?(&1, file_set, files))
  end

  defp problem_matches_files?(%{file_path: nil}, _file_set, _files), do: false

  defp problem_matches_files?(%{file_path: path}, file_set, files) do
    MapSet.member?(file_set, path) or path_fuzzy_matches?(path, files)
  end

  defp path_fuzzy_matches?(path, files) do
    Enum.any?(files, fn f ->
      basename_match = Path.basename(f) == Path.basename(path)
      basename_match and (String.ends_with?(f, path) or String.ends_with?(path, f))
    end)
  end

  @doc """
  Run BDD specs for modified spex files.
  """
  @spec run_spex([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_spex([], _scope) do
    Logger.info("[ValidateEdits] No spex files to run")
    {:ok, []}
  end

  def run_spex(spex_files, scope) do
    project_root = get_project_root(scope)
    Logger.info("[ValidateEdits] Running spex on #{length(spex_files)} files")

    opts = if project_root, do: [project_root: project_root, quiet: true], else: [quiet: true]

    case BddSpecs.run_specs(spex_files, opts) do
      {:ok, [], 0} ->
        Logger.info("[ValidateEdits] All spex passed")
        {:ok, []}

      {:ok, failures, _exit_code} when failures != [] ->
        Logger.info("[ValidateEdits] #{length(failures)} spex failures")
        {:ok, convert_spex_failures(failures)}

      {:ok, [], exit_code} when exit_code != 0 ->
        Logger.error("[ValidateEdits] Spex failed with exit code #{exit_code}")

        {:ok,
         [
           %Problem{
             severity: :error,
             source: "spex",
             source_type: :test,
             file_path: hd(spex_files),
             message: "BDD spec execution failed (exit code #{exit_code})",
             category: "spex_error"
           }
         ]}

      {:error, reason} ->
        Logger.error("[ValidateEdits] Spex error: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp convert_spex_failures(failures) do
    Enum.map(failures, fn failure ->
      %Problem{
        severity: :error,
        source: "spex",
        source_type: :test,
        file_path: (failure.error && failure.error.file) || "unknown",
        line: failure.error && failure.error.line,
        message: format_spex_message(failure),
        category: "spex_failure"
      }
    end)
  end

  defp format_spex_message(failure) do
    scenario_info = "#{failure.spex} > #{failure.scenario}"

    case failure.error do
      %{message: msg} when is_binary(msg) -> "#{scenario_info}: #{msg}"
      _ -> scenario_info
    end
  end

  @doc """
  Validate spec files against their document schemas.
  """
  @spec validate_spec_files([Path.t()]) :: {:ok, [Problem.t()]}
  def validate_spec_files([]) do
    Logger.info("[ValidateEdits] No spec files to validate")
    {:ok, []}
  end

  def validate_spec_files(spec_files) do
    Logger.info("[ValidateEdits] Validating #{length(spec_files)} spec files")

    problems =
      spec_files
      |> Enum.flat_map(&validate_single_spec/1)

    {:ok, problems}
  end

  defp validate_single_spec(path) do
    with {:ok, content} <- File.read(path),
         :ok <- validate_not_empty(content),
         doc_type <- document_type_from_path(path),
         {:ok, _doc} <- Documents.create_dynamic_document(content, doc_type) do
      []
    else
      {:error, :enoent} ->
        [spec_problem(path, "File not found", "file_error")]

      {:error, reason} when is_binary(reason) ->
        [spec_problem(path, reason, "validation_error")]

      {:error, reason} ->
        [spec_problem(path, inspect(reason), "validation_error")]
    end
  end

  defp validate_not_empty(""), do: {:error, "File is empty"}
  defp validate_not_empty(_), do: :ok

  defp spec_problem(path, message, category) do
    %Problem{
      severity: :error,
      source: "spec_validation",
      source_type: :document,
      file_path: path,
      message: message,
      category: category
    }
  end

  @doc """
  Determine document type from path.
  """
  @spec document_type_from_path(Path.t()) :: String.t()
  def document_type_from_path(path) do
    case extract_segments_after_docs_spec(path) do
      [_project, _file] -> "context_spec"
      _ -> "spec"
    end
  end

  defp extract_segments_after_docs_spec(path) do
    parts = Path.split(path)

    case Enum.find_index(parts, &(&1 == "spec")) do
      nil ->
        parts

      index when index > 0 ->
        if Enum.at(parts, index - 1) == "docs" do
          Enum.drop(parts, index + 1)
        else
          parts
        end

      _ ->
        parts
    end
  end

  # ============================================================================
  # Result Handling
  # ============================================================================

  @doc """
  Extract unique file paths from problems.
  """
  @spec extract_failed_files([Problem.t()]) :: [Path.t()]
  def extract_failed_files(problems) do
    problems
    |> Enum.map(& &1.file_path)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Format validation results for Claude Code stop hook output.
  """
  @spec format_output({:ok, :valid} | {:error, [Problem.t()]}) :: map()
  def format_output({:ok, :valid}), do: %{}

  def format_output({:error, problems}) when is_list(problems) do
    reason =
      ProblemRenderer.render_for_feedback(problems,
        context: "Validation errors found:",
        max_problems: 20
      )

    %{"decision" => "block", "reason" => reason}
  end

  def format_output({:error, reason}) when is_binary(reason) do
    %{"decision" => "block", "reason" => reason}
  end
end
