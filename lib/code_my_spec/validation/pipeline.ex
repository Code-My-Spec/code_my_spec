defmodule CodeMySpec.Validation.Pipeline do
  @moduledoc """
  Runs the generic validation pipeline on a set of files.

  Categorizes files by type, compiles the project, then runs tests,
  static analysis (Credo, Sobelow), BDD specs, and spec document validation.
  Returns a flat list of all problems found, filtered to only the provided files.
  """

  require Logger

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Documents
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Tests
  alias CodeMySpec.Tests.TestRun
  alias CodeMySpec.Users.Scope

  @doc """
  Run the full validation pipeline on a set of files.

  Returns a flat list of Problem structs for all issues found across all validators.
  """
  @spec run(Scope.t(), [Path.t()], keyword()) :: [Problem.t()]
  def run(scope, files, opts \\ [])
  def run(_scope, [], _opts), do: []

  def run(%Scope{} = scope, files, opts) when is_list(files) do
    categorized = categorize_files(files)
    clear_stale_problems(scope, categorized)

    case compile_project(scope, opts) do
      :ok ->
        {_, test_problems} = run_tests(categorized.test_files, scope, opts)
        {_, credo_problems} = run_credo(categorized.elixir_files, scope)
        {_, sobelow_problems} = run_sobelow(categorized.elixir_files, scope)
        {_, spex_problems} = run_spex(categorized.spex_files, scope)
        {_, spec_problems} = validate_spec_files(categorized.spec_files)

        test_problems ++ credo_problems ++ sobelow_problems ++ spex_problems ++ spec_problems

      {:error, reason} ->
        Logger.error("[Pipeline] Compilation failed: #{reason}")
        Problems.clear_problems_for_source(scope, [source: "compiler"], :all)

        [
          %Problem{
            severity: :error,
            source: "compiler",
            source_type: :static_analysis,
            file_path: "project",
            message: reason,
            category: "compilation_error"
          }
        ]
    end
  end

  @doc """
  Categorize a list of file paths by validator type.
  """
  @spec categorize_files([Path.t()]) :: %{
          spec_files: [Path.t()],
          test_files: [Path.t()],
          spex_files: [Path.t()],
          code_files: [Path.t()],
          elixir_files: [Path.t()]
        }
  def categorize_files(files) do
    spec_files = Enum.filter(files, &spec_file?/1)
    test_files = Enum.filter(files, &test_file?/1)
    spex_files = Enum.filter(files, &spex_file?/1)
    code_files = Enum.filter(files, &code_file?/1)

    elixir_files = code_files ++ test_files ++ spex_files

    mapped_test_files = map_code_to_test_files(code_files)
    all_test_files = Enum.uniq(test_files ++ mapped_test_files)

    Logger.info(
      "[Pipeline] Categorized - spec: #{length(spec_files)}, test: #{length(all_test_files)}, spex: #{length(spex_files)}, code: #{length(code_files)}, elixir: #{length(elixir_files)}"
    )

    %{
      spec_files: spec_files,
      test_files: all_test_files,
      spex_files: spex_files,
      code_files: code_files,
      elixir_files: elixir_files
    }
  end

  @doc """
  Clear stale problems for all categorized file groups, scoped by source.

  Each validator only clears problems matching its own source identifier
  for the files it checks. This prevents one validator from accidentally
  wiping another validator's results.
  """
  @spec clear_stale_problems(Scope.t() | nil, map()) :: :ok
  def clear_stale_problems(nil, _categorized), do: :ok

  def clear_stale_problems(%Scope{} = scope, categorized) do
    project_root = get_project_root(scope)

    rel = fn files -> relativize_paths(files, project_root) end

    # Tests: clear source_type: :test (excluding source: "spex") for test_files
    if categorized.test_files != [] do
      Problems.clear_problems_for_source(
        scope,
        [source_type: :test, exclude_source: "spex"],
        rel.(categorized.test_files)
      )
    end

    # Credo: clear source: "credo" for elixir_files
    if categorized.elixir_files != [] do
      Problems.clear_problems_for_source(scope, [source: "credo"], rel.(categorized.elixir_files))
    end

    # Sobelow: clear source: "sobelow" for elixir_files
    if categorized.elixir_files != [] do
      Problems.clear_problems_for_source(
        scope,
        [source: "sobelow"],
        rel.(categorized.elixir_files)
      )
    end

    # Spex: clear source: "spex" for spex_files
    if categorized.spex_files != [] do
      Problems.clear_problems_for_source(scope, [source: "spex"], rel.(categorized.spex_files))
    end

    # Spec validation: clear source: "spec_validation" for spec_files
    if categorized.spec_files != [] do
      Problems.clear_problems_for_source(
        scope,
        [source: "spec_validation"],
        rel.(categorized.spec_files)
      )
    end

    # Compiler: always clear project-wide (compilation is project-wide)
    Problems.clear_problems_for_source(scope, [source: "compiler"], :all)

    :ok
  end

  @doc """
  Compile the project once before running validators.
  """
  @spec compile_project(Scope.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def compile_project(scope, opts \\ [])

  def compile_project(nil, _opts) do
    Logger.info("[Pipeline] No scope, skipping compilation")
    :ok
  end

  def compile_project(%Scope{} = scope, opts) do
    project_root = get_project_root(scope)

    if project_root do
      Logger.info("[Pipeline] Compiling project at #{project_root}")

      compile_opts = [cwd: project_root]

      compile_opts =
        if f = opts[:compile_output_file],
          do: Keyword.put(compile_opts, :output_file, f),
          else: compile_opts

      case CodeMySpec.Compile.execute(compile_opts) do
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
  @spec run_tests([Path.t()], Scope.t() | nil, keyword()) :: {:ok, [Problem.t()]}
  def run_tests(test_files, scope, opts \\ [])

  def run_tests([], _scope, _opts) do
    {:ok, []}
  end

  def run_tests(_test_files, nil, _opts), do: {:ok, []}

  def run_tests(test_files, scope, opts) do
    project_root = get_project_root(scope)

    if is_nil(project_root) do
      {:ok, []}
    else
      test_files
      |> Enum.filter(&File.exists?/1)
      |> execute_tests(project_root, opts)
    end
  end

  defp execute_tests([], _project_root, _opts), do: {:ok, []}

  defp execute_tests(existing_files, project_root, opts) do
    Logger.info("[Pipeline] Running #{length(existing_files)} test files")

    test_opts = [project_root: project_root]

    test_opts =
      if f = opts[:test_output_file], do: Keyword.put(test_opts, :output_file, f), else: test_opts

    existing_files
    |> Tests.execute(test_opts)
    |> handle_test_result(existing_files)
  end

  defp handle_test_result({:ok, %TestRun{failures: failures}}, _files) when failures != [] do
    {:ok, convert_test_failures(failures)}
  end

  defp handle_test_result({:ok, %TestRun{execution_status: :error} = run}, files) do
    {:ok, parse_execution_errors(run.raw_output || "", files)}
  end

  defp handle_test_result({:ok, _}, _files), do: {:ok, []}

  defp handle_test_result({:error, reason}, _files) do
    Logger.error("[Pipeline] Test execution failed: #{inspect(reason)}")
    {:ok, []}
  end

  @doc """
  Run Credo static analysis on Elixir files via StaticAnalysis.Runner.
  """
  @spec run_credo([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_credo([], _scope), do: {:ok, []}
  def run_credo(_files, nil), do: {:ok, []}

  def run_credo(files, %Scope{} = scope) do
    Logger.info("[Pipeline] Running Credo on #{length(files)} files")

    case StaticAnalysis.run(scope, :credo, files: files) do
      {:ok, problems} ->
        {:ok, filter_problems_by_files(problems, files)}

      {:error, reason} ->
        Logger.warning("[Pipeline] Credo failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  @doc """
  Run Sobelow security analysis via StaticAnalysis.Runner.
  """
  @spec run_sobelow([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_sobelow([], _scope), do: {:ok, []}
  def run_sobelow(_files, nil), do: {:ok, []}

  def run_sobelow(files, %Scope{} = scope) do
    Logger.info("[Pipeline] Running Sobelow")

    case StaticAnalysis.run(scope, :sobelow) do
      {:ok, problems} ->
        {:ok, filter_problems_by_files(problems, files)}

      {:error, reason} ->
        Logger.warning("[Pipeline] Sobelow failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  @doc """
  Run BDD specs for modified spex files.
  """
  @spec run_spex([Path.t()], Scope.t() | nil) :: {:ok, [Problem.t()]}
  def run_spex([], _scope), do: {:ok, []}
  def run_spex(_spex_files, nil), do: {:ok, []}

  def run_spex(spex_files, scope) do
    project_root = get_project_root(scope)

    if is_nil(project_root) do
      {:ok, []}
    else
      Logger.info("[Pipeline] Running spex on #{length(spex_files)} files")

      opts = [project_root: project_root, quiet: true]

      case BddSpecs.run_specs(spex_files, opts) do
        {:ok, [], 0} ->
          {:ok, []}

        {:ok, failures, _exit_code} when failures != [] ->
          {:ok, convert_spex_failures(failures)}

        {:ok, [], exit_code} when exit_code != 0 ->
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

        {:error, _reason} ->
          {:ok, []}
      end
    end
  end

  @doc """
  Validate spec files against their document schemas.
  """
  @spec validate_spec_files([Path.t()]) :: {:ok, [Problem.t()]}
  def validate_spec_files([]), do: {:ok, []}

  def validate_spec_files(spec_files) do
    Logger.info("[Pipeline] Validating #{length(spec_files)} spec files")
    problems = Enum.flat_map(spec_files, &validate_single_spec/1)
    {:ok, problems}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp spec_file?(path), do: String.ends_with?(path, ".spec.md")
  defp test_file?(path), do: String.ends_with?(path, "_test.exs")
  defp spex_file?(path), do: String.ends_with?(path, "_spex.exs")

  defp code_file?(path) do
    (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")) and
      not test_file?(path) and not spex_file?(path)
  end

  defp lib_file?(path), do: String.contains?(path, "/lib/") and String.ends_with?(path, ".ex")

  defp map_code_to_test_files(code_files) do
    code_files
    |> Enum.filter(&lib_file?/1)
    |> Enum.map(&map_lib_to_test/1)
    |> Enum.filter(&File.exists?/1)
  end

  defp map_lib_to_test(lib_path) do
    relative =
      lib_path
      |> String.replace(~r{.*/lib/}, "")
      |> String.replace_suffix(".ex", "_test.exs")

    case Regex.run(~r{(.*/?)lib/}, lib_path) do
      [_, root] -> Path.join([root, "test", relative])
      _ -> Path.join(["test", relative])
    end
  end

  defp get_project_root(nil), do: nil
  defp get_project_root(%Scope{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd
  defp get_project_root(_scope), do: nil

  defp relativize_paths(paths, nil), do: paths

  defp relativize_paths(paths, project_root) do
    paths
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, project_root)
      # Include both forms so we match however the problem was stored
      if relative == path, do: [path], else: Enum.uniq([path, relative])
    end)
    |> Enum.uniq()
  end

  defp filter_problems_by_files(problems, files) do
    file_set = MapSet.new(files)

    Enum.filter(problems, fn
      %{file_path: nil} -> false
      %{file_path: path} -> MapSet.member?(file_set, path) or path_fuzzy_matches?(path, files)
    end)
  end

  defp path_fuzzy_matches?(path, files) do
    Enum.any?(files, fn f ->
      basename_match = Path.basename(f) == Path.basename(path)
      basename_match and (String.ends_with?(f, path) or String.ends_with?(path, f))
    end)
  end

  defp convert_test_failures(failures) do
    Enum.flat_map(failures, fn failure ->
      case failure.error do
        nil -> []
        error -> [CodeMySpec.Problems.from_test_failure(error)]
      end
    end)
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

  defp validate_single_spec(path) do
    with {:ok, content} <- File.read(path),
         :ok <- validate_not_empty(content),
         doc_type <- document_type_from_content(content, path),
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

  defp document_type_from_content(content, path) do
    case extract_type_section(content) do
      nil -> document_type_from_path(path)
      component_type -> Components.Registry.get_type(component_type).document_type
    end
  end

  defp extract_type_section(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
  end

  defp document_type_from_path(path) do
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
        if Enum.at(parts, index - 1) in ["docs", ".code_my_spec"] do
          Enum.drop(parts, index + 1)
        else
          parts
        end

      _ ->
        parts
    end
  end

  # Parse raw test output when execution_status is :error.
  # Extracts compiler warnings/errors and categorizes them properly
  # so they don't get confused with test failures.
  defp parse_execution_errors(raw_output, fallback_files) do
    compiler_problems = extract_compiler_problems(raw_output)

    if compiler_problems != [] do
      compiler_problems
    else
      # Couldn't parse — fall back to generic but still tag as compilation
      [
        %Problem{
          severity: :error,
          source: "compiler",
          source_type: :static_analysis,
          file_path: hd(fallback_files),
          message:
            "Test execution failed due to compilation errors. Raw output: #{String.slice(raw_output, 0..300)}",
          category: "compilation_error"
        }
      ]
    end
  end

  # Extract structured compiler problems from raw mix output.
  # Matches the standard Elixir compiler warning/error format:
  #   warning: message (file.ex:line)
  #   or the multi-line format with │ and └─ file:line
  @compiler_warning_re ~r/warning: (.+?)(?:\n.*?)*?└─ (.+?):(\d+)/
  @compiler_error_re ~r/\*\* \((\w+)\) (.+?):(\d+): (.+)/

  defp extract_compiler_problems(raw_output) do
    warning_problems =
      Regex.scan(@compiler_warning_re, raw_output)
      |> Enum.map(fn [_full, message, file, line] ->
        %Problem{
          severity: :warning,
          source: "compiler",
          source_type: :static_analysis,
          file_path: String.trim(file),
          line: String.to_integer(line),
          message: String.trim(message),
          category: "compiler_warning"
        }
      end)

    error_problems =
      Regex.scan(@compiler_error_re, raw_output)
      |> Enum.map(fn [_full, _error_type, file, line, message] ->
        %Problem{
          severity: :error,
          source: "compiler",
          source_type: :static_analysis,
          file_path: String.trim(file),
          line: String.to_integer(line),
          message: String.trim(message),
          category: "compilation_error"
        }
      end)

    warning_problems ++ error_problems
  end
end
