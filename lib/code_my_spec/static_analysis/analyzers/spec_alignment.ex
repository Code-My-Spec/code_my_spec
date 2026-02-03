defmodule CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment do
  @moduledoc """
  Custom analyzer that validates implementation matches specification definitions. Checks
  function signatures, type specs, and test assertions against spec documents. Reads spec
  files from the docs/spec directory, parses them using the Documents context, then
  compares parsed functions against actual implementation and test files to detect
  misalignment. Reports Problems for missing functions, mismatched specs, and missing or
  extra test assertions.
  """

  @behaviour CodeMySpec.StaticAnalysis.AnalyzerBehaviour

  alias CodeMySpec.Code.ElixirAst
  alias CodeMySpec.Documents.MarkdownParser
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Users.Scope

  require Logger

  # Callbacks

  @impl true
  @spec name() :: String.t()
  def name, do: "spec_alignment"

  @impl true
  @spec available?(Scope.t()) :: boolean()
  def available?(%Scope{active_project: project}) do
    with false <- is_nil(project),
         false <- is_nil(project.code_repo),
         spec_dir <- Path.join(project.code_repo, "docs/spec"),
         true <- File.dir?(spec_dir) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  @spec run(Scope.t(), keyword()) :: {:ok, [Problem.t()]} | {:error, String.t()}
  def run(%Scope{active_project: project, active_project_id: project_id} = _scope, opts \\ []) do
    with {:ok, code_repo} <- validate_project(project),
         {:ok, spec_dir} <- get_spec_directory(code_repo),
         {:ok, spec_files} <- find_spec_files(spec_dir, opts[:paths]) do
      problems =
        spec_files
        |> Enum.flat_map(&analyze_spec_file(&1, code_repo, project_id))

      {:ok, problems}
    end
  rescue
    exception ->
      Logger.error("SpecAlignment analyzer crashed: #{inspect(exception)}")
      {:error, "SpecAlignment analyzer crashed: #{Exception.message(exception)}"}
  end

  # Private functions

  defp validate_project(%{code_repo: nil}), do: {:error, "Project has no code_repo configured"}
  defp validate_project(%{code_repo: code_repo}), do: {:ok, code_repo}
  defp validate_project(nil), do: {:error, "No project in scope"}

  defp get_spec_directory(code_repo) do
    spec_dir = Path.join(code_repo, "docs/spec")

    if File.dir?(spec_dir) do
      {:ok, spec_dir}
    else
      {:error, "Spec directory does not exist: #{spec_dir}"}
    end
  end

  defp find_spec_files(_spec_dir, spec_file: spec_file) when is_binary(spec_file) do
    if File.exists?(spec_file), do: {:ok, [spec_file]}, else: {:ok, []}
  end

  defp find_spec_files(spec_dir, nil) do
    spec_files =
      Path.join(spec_dir, "**/*.spec.md")
      |> Path.wildcard()

    {:ok, spec_files}
  end

  defp find_spec_files(spec_dir, paths) when is_list(paths) do
    spec_files =
      paths
      |> Enum.flat_map(fn path ->
        full_path = Path.join([spec_dir, path, "**/*.spec.md"])
        Path.wildcard(full_path)
      end)
      |> Enum.uniq()

    {:ok, spec_files}
  end

  defp analyze_spec_file(spec_file_path, code_repo, project_id) do
    with {:ok, content} <- File.read(spec_file_path),
         {:ok, module_name} <- extract_module_name_from_content(content),
         {:ok, sections} <- MarkdownParser.parse(content),
         impl_path <- determine_impl_path(module_name, code_repo),
         test_path <- determine_test_path(module_name, code_repo) do
      # Only analyze if implementation exists
      if File.exists?(impl_path) do
        functions = Map.get(sections, "functions", [])
        analyze_module_alignment(functions, impl_path, test_path, spec_file_path, project_id)
      else
        # No problems for modules that don't exist yet (TDD mode)
        []
      end
    else
      {:error, reason} ->
        # Create a problem about the invalid spec
        [
          %Problem{
            severity: :error,
            source_type: :static_analysis,
            source: "spec_alignment",
            file_path: spec_file_path,
            line: 1,
            message: "Failed to parse spec file: #{inspect(reason)}",
            category: "spec_parsing",
            project_id: project_id
          }
        ]
    end
  rescue
    exception ->
      Logger.warning("Failed to analyze spec file #{spec_file_path}: #{inspect(exception)}")
      []
  end

  defp extract_module_name_from_content(content) do
    case String.split(content, "\n", parts: 2) do
      ["# " <> module_name | _] -> {:ok, String.trim(module_name)}
      _ -> {:error, "No H1 heading found in spec file"}
    end
  end

  defp determine_impl_path(module_name, code_repo) do
    # Convert module name to file path
    # e.g., "MyApp.User.Schema" -> "lib/my_app/user/schema.ex"
    relative_path =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    Path.join([code_repo, "lib", "#{relative_path}.ex"])
  end

  defp determine_test_path(module_name, code_repo) do
    # Convert module name to test file path
    # e.g., "MyApp.User.Schema" -> "test/my_app/user/schema_test.exs"
    relative_path =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    Path.join([code_repo, "test", "#{relative_path}_test.exs"])
  end

  defp analyze_module_alignment(spec_functions, impl_path, test_path, _spec_file_path, project_id)
       when is_list(spec_functions) do
    impl_problems = compare_implementations(spec_functions, impl_path, project_id)
    test_problems = compare_test_assertions(spec_functions, test_path, project_id)

    impl_problems ++ test_problems
  end

  defp compare_implementations(spec_functions, impl_path, project_id) do
    case ElixirAst.get_public_functions(impl_path) do
      {:ok, impl_functions} ->
        # Convert spec functions to map for easy lookup
        spec_fn_map = build_spec_function_map(spec_functions)
        impl_fn_map = build_impl_function_map(impl_functions)

        missing_problems =
          find_missing_functions(spec_fn_map, impl_fn_map, impl_path, project_id)

        extra_problems = find_extra_functions(impl_fn_map, spec_fn_map, impl_path, project_id)

        mismatch_problems =
          find_mismatched_specs(spec_fn_map, impl_fn_map, impl_path, project_id)

        missing_problems ++ extra_problems ++ mismatch_problems

      {:error, _reason} ->
        # Can't parse implementation file - it might have syntax errors
        # Return empty list to handle gracefully
        []
    end
  end

  defp build_spec_function_map(spec_functions) do
    spec_functions
    |> Enum.map(fn func ->
      # Parse function name and arity from the name field (e.g., "hello/0")
      case parse_function_signature(func.name) do
        {:ok, name, arity} -> {{name, arity}, func}
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp build_impl_function_map(impl_functions) do
    impl_functions
    |> Enum.map(fn func -> {{func.name, func.arity}, func} end)
    |> Map.new()
  end

  defp parse_function_signature(name) when is_binary(name) do
    case String.split(name, "/") do
      [func_name, arity_str] ->
        case Integer.parse(arity_str) do
          {arity, ""} -> {:ok, String.to_atom(func_name), arity}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp find_missing_functions(spec_fn_map, impl_fn_map, impl_path, project_id) do
    spec_fn_map
    |> Enum.filter(fn {{name, arity}, _spec_func} ->
      not Map.has_key?(impl_fn_map, {name, arity})
    end)
    |> Enum.map(fn {{name, arity}, _spec_func} ->
      %Problem{
        severity: :error,
        source_type: :static_analysis,
        source: "spec_alignment",
        file_path: impl_path,
        line: 1,
        message:
          "Missing function implementation: #{name}/#{arity} is defined in spec but not implemented",
        category: "missing_implementation",
        project_id: project_id
      }
    end)
  end

  defp find_extra_functions(impl_fn_map, spec_fn_map, impl_path, project_id) do
    impl_fn_map
    |> Enum.filter(fn {{name, arity}, _impl_func} ->
      not Map.has_key?(spec_fn_map, {name, arity})
    end)
    |> Enum.map(fn {{name, arity}, _impl_func} ->
      %Problem{
        severity: :warning,
        source_type: :static_analysis,
        source: "spec_alignment",
        file_path: impl_path,
        line: 1,
        message:
          "Extra function found: #{name}/#{arity} is implemented but not documented in spec",
        category: "extra_function",
        project_id: project_id
      }
    end)
  end

  defp find_mismatched_specs(spec_fn_map, impl_fn_map, impl_path, project_id) do
    spec_fn_map
    |> Enum.filter(fn {{name, arity}, _spec_func} ->
      Map.has_key?(impl_fn_map, {name, arity})
    end)
    |> Enum.flat_map(fn {{name, arity}, spec_func} ->
      impl_func = Map.get(impl_fn_map, {name, arity})
      compare_type_specs(name, arity, spec_func, impl_func, impl_path, project_id)
    end)
  end

  defp compare_type_specs(name, arity, spec_func, impl_func, impl_path, project_id) do
    spec_typespec = normalize_typespec(spec_func.spec)
    impl_typespec = normalize_typespec(impl_func.spec)

    if spec_typespec && impl_typespec && spec_typespec != impl_typespec do
      [
        %Problem{
          severity: :error,
          source_type: :static_analysis,
          source: "spec_alignment",
          file_path: impl_path,
          line: 1,
          message:
            "Type signature mismatch for #{name}/#{arity}: spec defines '#{spec_typespec}' but implementation has '#{impl_typespec}'",
          category: "spec_mismatch",
          project_id: project_id
        }
      ]
    else
      []
    end
  end

  defp normalize_typespec(nil), do: nil

  defp normalize_typespec(spec) when is_binary(spec) do
    # Remove @spec prefix and normalize whitespace
    spec
    |> String.replace(~r/@spec\s+/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp compare_test_assertions(spec_functions, test_path, project_id) do
    # Only check tests if test file exists
    if File.exists?(test_path) do
      case ElixirAst.get_test_assertions(test_path) do
        {:ok, test_assertions} ->
          compare_test_assertions_with_spec(
            spec_functions,
            test_assertions,
            test_path,
            project_id
          )

        {:error, _reason} ->
          # Can't parse test file - handle gracefully
          []
      end
    else
      # No test file exists - this is OK in TDD mode
      []
    end
  end

  defp compare_test_assertions_with_spec(spec_functions, test_assertions, test_path, project_id) do
    # Build map of function name -> test assertions from spec
    spec_assertions_map = build_spec_assertions_map(spec_functions)

    # Build map of function name -> test names from actual tests
    test_names_map = build_test_names_map(test_assertions)

    missing_test_problems =
      find_missing_test_assertions(spec_assertions_map, test_names_map, test_path, project_id)

    extra_test_problems =
      find_extra_test_assertions(test_names_map, spec_assertions_map, test_path, project_id)

    missing_test_problems ++ extra_test_problems
  end

  defp build_spec_assertions_map(spec_functions) do
    spec_functions
    |> Enum.map(fn func ->
      case parse_function_signature(func.name) do
        {:ok, name, arity} ->
          {{name, arity}, func.test_assertions || []}

        :error ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp build_test_names_map(test_assertions) do
    # Group tests by their describe blocks (which typically correspond to functions)
    test_assertions
    |> Enum.group_by(fn test ->
      # Extract function signature from describe block
      # e.g., "hello/0" or first describe block
      extract_function_from_describe(test.describe_blocks)
    end)
    |> Enum.map(fn {func_sig, tests} ->
      test_names = Enum.map(tests, & &1.test_name)
      {func_sig, test_names}
    end)
    |> Map.new()
  end

  defp extract_function_from_describe([]), do: nil

  defp extract_function_from_describe([first_describe | _rest]) do
    # Try to extract function signature like "hello/0" from describe block
    case parse_function_signature(first_describe) do
      {:ok, name, arity} -> {name, arity}
      :error -> first_describe
    end
  end

  defp find_missing_test_assertions(spec_assertions_map, test_names_map, test_path, project_id) do
    spec_assertions_map
    |> Enum.flat_map(fn {{name, arity}, spec_assertions} ->
      actual_tests = Map.get(test_names_map, {name, arity}, [])

      spec_assertions
      |> Enum.reject(&assertion_has_matching_test?(&1, actual_tests))
      |> Enum.map(fn missing_assertion ->
        %Problem{
          severity: :warning,
          source_type: :static_analysis,
          source: "spec_alignment",
          file_path: test_path,
          line: 1,
          message:
            "Missing test assertion for #{name}/#{arity}: spec requires test for '#{missing_assertion}'",
          category: "missing_test",
          project_id: project_id
        }
      end)
    end)
  end

  defp assertion_has_matching_test?(assertion, actual_tests) do
    Enum.any?(actual_tests, &strings_similar?(assertion, &1))
  end

  defp find_extra_test_assertions(test_names_map, spec_assertions_map, test_path, project_id) do
    test_names_map
    |> Enum.flat_map(fn
      {{name, arity}, actual_tests} when is_atom(name) and is_integer(arity) ->
        spec_assertions = Map.get(spec_assertions_map, {name, arity}, [])
        find_extra_tests_for_function(name, arity, actual_tests, spec_assertions, test_path, project_id)

      {_other_key, _tests} ->
        []
    end)
  end

  defp find_extra_tests_for_function(_name, _arity, _actual_tests, [], _test_path, _project_id), do: []

  defp find_extra_tests_for_function(name, arity, actual_tests, spec_assertions, test_path, project_id) do
    actual_tests
    |> Enum.reject(&test_has_matching_assertion?(&1, spec_assertions))
    |> Enum.map(fn extra_test ->
      %Problem{
        severity: :warning,
        source_type: :static_analysis,
        source: "spec_alignment",
        file_path: test_path,
        line: 1,
        message:
          "Extra test found for #{name}/#{arity}: '#{extra_test}' is not documented in spec",
        category: "extra_test",
        project_id: project_id
      }
    end)
  end

  defp test_has_matching_assertion?(test_name, spec_assertions) do
    Enum.any?(spec_assertions, &strings_similar?(&1, test_name))
  end

  defp strings_similar?(str1, str2) do
    # Normalize both strings - remove punctuation and normalize whitespace
    normalized1 = normalize_string(str1)
    normalized2 = normalize_string(str2)

    # Check for exact match after normalization or significant overlap
    cond do
      normalized1 == normalized2 ->
        true

      # Check if one string contains at least 80% of the words from the other
      String.length(normalized1) > 5 and String.length(normalized2) > 5 ->
        words1 = String.split(normalized1)
        words2 = String.split(normalized2)
        calculate_overlap(words1, words2) >= 0.8

      # For short strings, require exact match
      true ->
        normalized1 == normalized2
    end
  end

  defp normalize_string(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp calculate_overlap(words1, words2) do
    set1 = MapSet.new(words1)
    set2 = MapSet.new(words2)

    intersection_size = MapSet.intersection(set1, set2) |> MapSet.size()
    min_size = min(MapSet.size(set1), MapSet.size(set2))

    if min_size == 0, do: 0.0, else: intersection_size / min_size
  end
end
