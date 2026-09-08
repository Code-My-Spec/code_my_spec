defmodule CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment do
  @moduledoc """
  Custom analyzer that validates implementation matches specification definitions. Checks
  function signatures, type specs, and test assertions against spec documents. Reads spec
  files from the .code_my_spec/spec directory, parses them using the Documents context, then
  compares parsed functions against actual implementation and test files to detect
  misalignment. Reports Problems for missing functions, mismatched specs, and missing or
  extra test assertions.
  """

  @behaviour CodeMySpec.StaticAnalysis.AnalyzerBehaviour

  alias CodeMySpec.Code.ElixirAst
  alias CodeMySpec.Documents.MarkdownParser
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Users.Scope

  require Logger

  # Callbacks

  @impl true
  @spec name() :: String.t()
  def name, do: "spec_alignment"

  @impl true
  @spec available?(Scope.t()) :: boolean()
  def available?(%Scope{cwd: cwd} = scope) when is_binary(cwd) and cwd != "" do
    # file_exists?, not exec_file_exists?: the spec directory is a domain file,
    # read through read_file/2. Only tool-installation checks belong to the
    # shell's filesystem.
    env = StaticAnalysis.resolve_environment([], scope, cwd)
    Environments.file_exists?(env, Paths.spec_dir())
  rescue
    _ -> false
  end

  def available?(_scope), do: false

  @impl true
  @spec run(Scope.t(), keyword()) :: {:ok, [Problem.t()]} | {:error, String.t()}
  def run(%Scope{active_project_id: project_id} = scope, opts \\ []) do
    cwd = opts[:cwd] || scope.cwd

    if is_nil(cwd) or cwd == "" do
      {:error, "No working directory available"}
    else
      env = StaticAnalysis.resolve_environment(opts, scope, cwd)

      with {:ok, spec_files} <- find_spec_files(env, opts) do
        problems =
          spec_files
          |> Enum.flat_map(&analyze_spec_file(&1, env, project_id))

        {:ok, problems}
      end
    end
  rescue
    exception ->
      Logger.error("SpecAlignment analyzer crashed: #{inspect(exception)}")
      {:error, "SpecAlignment analyzer crashed: #{Exception.message(exception)}"}
  end

  # Private functions

  # stream_files/3 rather than glob/2: its contract says emitted paths are
  # relative to the environment's cwd, and every path this analyzer produces —
  # including the ones that end up in Problem.file_path — is project-relative.
  defp find_spec_files(env, opts) when is_list(opts) do
    case Keyword.get(opts, :paths) do
      nil ->
        # stream_files/3 silently skips roots that do not exist, so the missing
        # spec directory has to be checked separately. "The project has no spec
        # directory" and "the spec directory holds no specs" are different
        # answers — the first means the project is not set up, and the analyzer
        # reported it as an error before this went through the environment.
        if Environments.file_exists?(env, Paths.spec_dir()) do
          spec_files(env)
        else
          {:error, "Spec directory does not exist: #{Paths.spec_dir()}"}
        end

      paths when is_list(paths) ->
        {:ok, Enum.filter(paths, &Environments.file_exists?(env, &1))}
    end
  end

  # `stream_files/3` does not always return something enumerable.
  #
  # `Environments.Harness` answers `{:error, :not_supported_on_harness}` — the
  # server holds no disk, and streaming a remote working copy's files is not
  # something the channel offers. Piped straight into `Enum.filter/2` that
  # raised `Protocol.UndefinedError`, and because this runs inside
  # `HarnessProjectChannel`, the crash took the channel down. Every stop then
  # timed out with "the harness never got to ask", the harness reconnected, and
  # the next stop did it again — on every worktree at once, since they share the
  # server.
  #
  # The environment behaviour is right to refuse rather than invent an answer;
  # this is the caller not having been swept when `Environments.Harness` was
  # added. An error here is reported as an analyzer that could not look, which
  # is what it is — the same distinction `Environments.unobservable?/1` draws,
  # and the opposite of returning `[]`, which would say the project has no specs
  # and delete every spec-alignment Problem it has.
  defp spec_files(env) do
    case Environments.stream_files(env, [Paths.spec_dir()]) do
      {:error, reason} ->
        {:error,
         "cannot list spec files in this environment (#{inspect(reason)}) — " <>
           "the analyzer needs a working copy it can read"}

      stream ->
        {:ok, Enum.filter(stream, &String.ends_with?(&1, ".spec.md"))}
    end
  end

  defp analyze_spec_file(spec_file_path, env, project_id) do
    with {:ok, content} <- Environments.read_file(env, spec_file_path),
         {:ok, module_name} <- extract_module_name_from_content(content),
         {:ok, sections} <- MarkdownParser.parse(content),
         impl_path <- determine_impl_path(module_name),
         test_path <- determine_test_path(module_name) do
      # Only analyze if implementation exists
      if Environments.file_exists?(env, impl_path) do
        functions = Map.get(sections, "functions", [])

        function_problems =
          analyze_module_alignment(
            functions,
            impl_path,
            test_path,
            spec_file_path,
            project_id,
            env
          )

        # Also check top-level Test Assertions (used by LiveView/component specs)
        top_level_problems =
          case Map.get(sections, "test assertions") do
            nil ->
              []

            assertions_text ->
              check_top_level_test_assertions(assertions_text, test_path, project_id, env)
          end

        function_problems ++ top_level_problems
      else
        # No problems for modules that don't exist yet (TDD mode)
        []
      end
    else
      {:error, reason} ->
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
  end

  defp extract_module_name_from_content(content) do
    case String.split(content, "\n", parts: 2) do
      ["# " <> module_name | _] -> {:ok, String.trim(module_name)}
      _ -> {:error, "No H1 heading found in spec file"}
    end
  end

  defp determine_impl_path(module_name) do
    # Convert module name to file path
    # e.g., "MyApp.User.Schema" -> "lib/my_app/user/schema.ex"
    relative_path =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    Path.join(["lib", "#{relative_path}.ex"])
  end

  defp determine_test_path(module_name) do
    # Convert module name to test file path
    # e.g., "MyApp.User.Schema" -> "test/my_app/user/schema_test.exs"
    relative_path =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    Path.join(["test", "#{relative_path}_test.exs"])
  end

  defp analyze_module_alignment(
         spec_functions,
         impl_path,
         test_path,
         _spec_file_path,
         project_id,
         env
       )
       when is_list(spec_functions) do
    impl_problems = compare_implementations(spec_functions, impl_path, project_id, env)
    test_problems = compare_test_assertions(spec_functions, test_path, project_id, env)

    impl_problems ++ test_problems
  end

  defp compare_implementations(spec_functions, impl_path, project_id, env) do
    case read_and_parse(env, impl_path, &ElixirAst.public_functions_from_source/1) do
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
    |> Enum.map(fn func -> {{Atom.to_string(func.name), func.arity}, func} end)
    |> Map.new()
  end

  defp parse_function_signature(name) when is_binary(name) do
    case String.split(name, "/") do
      [func_name, arity_str] ->
        case Integer.parse(arity_str) do
          {arity, ""} -> {:ok, func_name, arity}
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

  defp compare_test_assertions(spec_functions, test_path, project_id, env) do
    # Only check tests if test file exists
    if Environments.file_exists?(env, test_path) do
      case read_and_parse(env, test_path, &ElixirAst.test_assertions_from_source/1) do
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
        normalized_assertion = normalize_string(missing_assertion)
        normalized_tests = Enum.map(actual_tests, &normalize_string/1)

        %Problem{
          severity: :warning,
          source_type: :static_analysis,
          source: "spec_alignment",
          file_path: test_path,
          line: 1,
          message:
            "Missing test assertion for #{name}/#{arity}: spec requires test for '#{missing_assertion}' (normalized: '#{normalized_assertion}'). Existing tests normalized: #{inspect(normalized_tests)}",
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
      {{name, arity}, actual_tests} when is_binary(name) and is_integer(arity) ->
        spec_assertions = Map.get(spec_assertions_map, {name, arity}, [])

        find_extra_tests_for_function(
          name,
          arity,
          actual_tests,
          spec_assertions,
          test_path,
          project_id
        )

      {_other_key, _tests} ->
        []
    end)
  end

  defp find_extra_tests_for_function(_name, _arity, _actual_tests, [], _test_path, _project_id),
    do: []

  defp find_extra_tests_for_function(
         name,
         arity,
         actual_tests,
         spec_assertions,
         test_path,
         project_id
       ) do
    actual_tests
    |> Enum.reject(&test_has_matching_assertion?(&1, spec_assertions))
    |> Enum.map(fn extra_test ->
      normalized_test = normalize_string(extra_test)
      normalized_assertions = Enum.map(spec_assertions, &normalize_string/1)

      %Problem{
        severity: :warning,
        source_type: :static_analysis,
        source: "spec_alignment",
        file_path: test_path,
        line: 1,
        message:
          "Extra test found for #{name}/#{arity}: '#{extra_test}' is not documented in spec (normalized: '#{normalized_test}'). Spec assertions normalized: #{inspect(normalized_assertions)}",
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
    |> String.replace("_", " ")
    |> String.replace(~r/[^a-z0-9\s]/u, "")
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

  # -- Top-level Test Assertions (LiveView/component specs) --

  @doc """
  Check a test file against its spec's Test Assertions section.

  Returns `{:ok, :aligned}` or `{:ok, :misaligned, errors}` where errors
  is a map with `:missing` and `:extra` lists.

  Used by FileSync to validate test files during sync.
  """
  @spec check_test_alignment(String.t(), String.t()) ::
          {:ok, :aligned} | {:ok, :misaligned, map()}
  def check_test_alignment(spec_content, test_content) do
    spec_assertions = extract_top_level_assertions(spec_content)

    if spec_assertions == [],
      do: {:ok, :aligned},
      else: compare_assertions_to_test_ast(spec_assertions, test_content)
  end

  defp compare_assertions_to_test_ast(spec_assertions, test_content) do
    case Code.string_to_quoted(test_content) do
      {:ok, ast} -> classify_alignment(spec_assertions, extract_test_names(ast))
      {:error, _} -> {:ok, :aligned}
    end
  end

  defp classify_alignment(spec_assertions, test_names) do
    missing = Enum.reject(spec_assertions, &assertion_has_matching_test?(&1, test_names))
    extra = Enum.reject(test_names, &test_has_matching_assertion?(&1, spec_assertions))

    if missing == [] and extra == [],
      do: {:ok, :aligned},
      else: {:ok, :misaligned, %{missing: missing, extra: extra}}
  end

  defp check_top_level_test_assertions(assertions_text, test_path, project_id, env) do
    spec_assertions = parse_assertion_list(assertions_text)

    if spec_assertions == [] or not Environments.file_exists?(env, test_path) do
      []
    else
      compare_top_level_assertions(spec_assertions, test_path, project_id, env)
    end
  end

  # Read through the environment, parse in memory. ElixirAst's path-taking
  # functions do their own File.read, which would go to the wrong host.
  defp read_and_parse(env, path, parse) do
    with {:ok, content} <- Environments.read_file(env, path) do
      parse.(content)
    end
  end

  defp compare_top_level_assertions(spec_assertions, test_path, project_id, env) do
    case read_and_parse(env, test_path, &ElixirAst.test_assertions_from_source/1) do
      {:ok, test_assertions} ->
        test_names = test_assertions |> Enum.map(& &1.test_name) |> Enum.uniq()

        missing =
          spec_assertions
          |> Enum.reject(&assertion_has_matching_test?(&1, test_names))
          |> Enum.map(&missing_assertion_problem(&1, test_path, project_id))

        extra =
          test_names
          |> Enum.reject(&test_has_matching_assertion?(&1, spec_assertions))
          |> Enum.map(&extra_test_problem(&1, test_path, project_id))

        missing ++ extra

      {:error, _} ->
        []
    end
  end

  defp missing_assertion_problem(assertion, test_path, project_id) do
    %Problem{
      severity: :warning,
      source_type: :static_analysis,
      source: "spec_alignment",
      file_path: test_path,
      line: 1,
      message: "Missing test for spec assertion: '#{assertion}'",
      category: "missing_test",
      project_id: project_id
    }
  end

  defp extra_test_problem(test_name, test_path, project_id) do
    %Problem{
      severity: :warning,
      source_type: :static_analysis,
      source: "spec_alignment",
      file_path: test_path,
      line: 1,
      message: "Test '#{test_name}' has no matching spec assertion",
      category: "extra_test",
      project_id: project_id
    }
  end

  @doc false
  def extract_top_level_assertions(spec_content) do
    spec_content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^## Test Assertions/i)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(&String.replace_prefix(&1, "- ", ""))
  end

  defp parse_assertion_list(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(&String.replace_prefix(&1, "- ", ""))
  end

  defp parse_assertion_list(_), do: []

  defp extract_test_names(ast) do
    extract_tests_from_ast(ast, []) |> Enum.reverse() |> Enum.uniq()
  end

  defp extract_tests_from_ast({:defmodule, _, [_, [do: body]]}, acc),
    do: extract_tests_from_ast(body, acc)

  defp extract_tests_from_ast({:__block__, _, exprs}, acc),
    do: Enum.reduce(exprs, acc, &extract_tests_from_ast/2)

  defp extract_tests_from_ast({:describe, _, [_name, [do: body]]}, acc),
    do: extract_tests_from_ast(body, acc)

  defp extract_tests_from_ast({:test, _, [name | _]}, acc) when is_binary(name), do: [name | acc]
  defp extract_tests_from_ast(_, acc), do: acc
end
