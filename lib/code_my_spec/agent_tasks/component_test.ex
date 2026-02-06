defmodule CodeMySpec.AgentTasks.ComponentTest do
  @moduledoc """
  Consolidated component test session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the test writing prompt
  - `evaluate/3` - Called by stop hook to run tests and validate quality
  """

  alias CodeMySpec.{
    Compile,
    Components,
    Components.Component,
    Environments,
    Rules,
    StaticAnalysis,
    Tests,
    Utils
  }

  @required_alignment_score 0.9
  @required_overall_score 0.95

  @doc """
  Generate the command/prompt for Claude to write component tests.

  Called by the slash command to build the prompt with:
  - Spec file location
  - Test rules
  - Similar components for patterns
  - TDD context (implementation exists or not)

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    with {:ok, test_rules} <- get_test_rules(scope, component) do
      similar_components = Components.list_similar_components(scope, component)
      build_test_prompt(session, test_rules, similar_components)
    end
  end

  @doc """
  Evaluate Claude's output by running tests and checking quality.

  Called by the stop hook after Claude writes tests. This:
  1. Checks compilation
  2. Runs tests
  3. Validates TDD state (tests should fail if no implementation)
  4. Checks spec alignment (tests match spec assertions)

  Returns:
  - {:ok, :valid} if all quality checks pass
  - {:ok, :invalid, errors} if quality checks fail (for Claude to fix)
  - {:error, reason} if something went wrong
  """
  def evaluate(scope, session, opts \\ []) do
    %{component: component, project: project} = session

    %{test_file: test_file_path, code_file: code_file_path} =
      Utils.component_files(component, project)

    # First check that test file exists
    case check_file_exists(session, test_file_path) do
      false ->
        {:ok, :invalid, format_missing_file_error("test", test_file_path)}

      true ->
        implementation_exists = check_implementation_exists(session, code_file_path)
        tdd_mode = not implementation_exists

        working_dir = session[:working_dir]

        # Check compilation
        case check_compilation(working_dir) do
          {:ok, compile_result} when compile_result.score == 0.0 ->
            {:ok, :invalid, format_compilation_errors(compile_result)}

          {:ok, compile_result} ->
            # Compilation passed, run quality checks
            # Ensure scope has cwd set for static analysis
            scope = ensure_scope_cwd(scope, working_dir)

            run_quality_checks(
              scope,
              session,
              component,
              project,
              compile_result,
              test_file_path,
              tdd_mode,
              opts
            )
        end
    end
  end

  # Private functions

  defp get_test_rules(_scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "test")
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_test_prompt(session, test_rules, similar_components) do
    %{project: project, component: component} = session
    test_rules_text = Enum.map_join(test_rules, "\n\n", & &1.content)
    similar_text = format_similar_components(project, similar_components)

    %{spec_file: spec_file_path, test_file: test_file_path, code_file: code_file_path} =
      Utils.component_files(component, project)

    implementation_exists = check_implementation_exists(session, code_file_path)

    tdd_section =
      if implementation_exists do
        """
        The component implementation already exists.
        Write tests that validate the existing implementation against the design specification.
        """
      else
        """
        The component doesn't exist yet.
        You are to write the tests before we implement the module, TDD style.
        Only write the tests defined in the Test Assertions section of the design.
        If you want to write more cases, you must modify the design first.
        """
      end

    parent_spec_file_path =
      case component.parent_component do
        %Component{} = parent_component ->
          %{spec_file: parent_spec_file_path} = Utils.component_files(parent_component, project)
          parent_spec_file_path

        _ ->
          "no parent design"
      end

    prompt =
      """
      Generate tests and fixtures for the following Phoenix component.
      #{tdd_section}

      Tests should be grouped by describe blocks that match the function signature EXACTLY.
      Any blocks that don't match the test assertions in the spec will be rejected and you'll have to redo them.

      describe "get_test_assertions/1" do
        test "extracts test names from test blocks", %{tmp_dir: tmp_dir} do
          ...test code
        end
      end

      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Type: #{component.type}

      Parent Context Design File: #{parent_spec_file_path}
      Component Design File: #{spec_file_path}

      Similar Components (for test pattern inspiration):
      #{similar_text}

      Test Rules:
      #{test_rules_text}

      Write the test file to #{test_file_path}.

      Focus on:
      - Reading the design files to understand the component architecture and parent context
      - Creating reusable fixture functions for test data
      - Testing all public API functions
      - Testing edge cases and error conditions
      - Testing with valid and invalid data
      - Following test and fixture organization patterns from the rules
      - Only implementing the test assertions from the design file
      """

    {:ok, prompt}
  end

  defp format_similar_components(_project, []), do: "No similar components provided"

  defp format_similar_components(project, similar_components) do
    similar_components
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {component, index} ->
      files = Utils.component_files(component, project)

      """
      #{index}. #{component.name} (#{component.type})
         Description: #{component.description || "No description"}
         Spec: #{files.spec_file}
         Implementation: #{files.code_file}
         Test: #{files.test_file}
      """
      |> String.trim()
    end)
  end

  defp check_file_exists(session, file_path) do
    {:ok, environment} =
      Environments.create(session.environment_type, working_dir: session[:working_dir])

    Environments.file_exists?(environment, file_path)
  end

  defp check_implementation_exists(session, code_file_path) do
    check_file_exists(session, code_file_path)
  end

  defp format_missing_file_error(file_type, file_path) do
    """
    Required #{file_type} file does not exist: #{file_path}

    You must write the #{file_type} file before evaluation can proceed.
    Please create the file at the path shown above.
    """
  end

  defp check_compilation(working_dir) do
    opts = if working_dir, do: [cwd: working_dir], else: []

    case Compile.execute(opts) do
      %{status: :ok} ->
        {:ok, %{score: 1.0, errors: []}}

      %{status: :error, data: %{compiler_results: diagnostics}} ->
        errors = format_diagnostics(diagnostics)
        {:ok, %{score: 0.0, errors: errors}}
    end
  end

  defp ensure_scope_cwd(scope, nil), do: scope
  defp ensure_scope_cwd(scope, working_dir), do: Map.put(scope, :cwd, working_dir)

  defp format_diagnostics(diagnostics) when is_list(diagnostics) do
    Enum.map(diagnostics, fn
      %{message: message, file: file, position: %{line: line}} ->
        "#{file}:#{line}: #{message}"

      %{message: message, file: file} ->
        "#{file}: #{message}"

      %{message: message} ->
        message

      other ->
        inspect(other)
    end)
  end

  defp format_diagnostics(other), do: [inspect(other)]

  defp run_quality_checks(
         scope,
         session,
         component,
         project,
         compile_result,
         test_file_path,
         tdd_mode,
         _opts
       ) do
    working_dir = session[:working_dir]

    # Run tests to get test results
    case run_tests(test_file_path, working_dir) do
      {:ok, test_run} ->
        tdd_state_result = check_tdd_state(test_run, tdd_mode: tdd_mode)
        alignment_result = run_spec_alignment(scope, component, project, tdd_mode: tdd_mode)

        overall_score =
          (compile_result.score + tdd_state_result.score + alignment_result.score) / 3

        case validate_quality(compile_result, tdd_state_result, alignment_result, overall_score) do
          :ok ->
            {:ok, :valid}

          {:error, errors} ->
            feedback =
              format_quality_errors(
                errors,
                compile_result,
                tdd_state_result,
                alignment_result,
                overall_score
              )

            {:ok, :invalid, feedback}
        end

      {:error, {:parse_error, output}} ->
        {:ok, :invalid, "Tests could not run: #{output}"}
    end
  end

  defp run_tests(test_file_path, working_dir) do
    opts = if working_dir, do: [project_root: working_dir], else: []
    Tests.execute([test_file_path], opts)
  end

  defp validate_quality(compile_result, tdd_state_result, alignment_result, overall_score) do
    errors = []

    errors =
      if compile_result.score < 1.0 do
        errors ++ compile_result.errors
      else
        errors
      end

    errors =
      if tdd_state_result.score < 1.0 do
        errors ++ tdd_state_result.errors
      else
        errors
      end

    errors =
      if alignment_result.score < @required_alignment_score do
        alignment_error = """
        Test alignment score (#{Float.round(alignment_result.score, 2)}) is below required threshold (#{@required_alignment_score}).
        Tests must be at least 90% aligned with spec assertions.
        """

        errors ++ [alignment_error | alignment_result.errors]
      else
        errors
      end

    errors =
      if overall_score < @required_overall_score do
        overall_error = """
        Overall quality score (#{Float.round(overall_score, 2)}) is below required threshold (#{@required_overall_score}).
        """

        errors ++ [overall_error]
      else
        errors
      end

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp format_compilation_errors(compile_result) do
    """
    Compilation failed:

    #{Enum.map_join(compile_result.errors, "\n", &String.trim/1)}

    Please fix the compilation errors in the test file.
    """
  end

  defp format_quality_errors(
         errors,
         compile_result,
         tdd_state_result,
         alignment_result,
         overall_score
       ) do
    """
    Quality checks failed:

    Compilation Score: #{compile_result.score}
    TDD State Score: #{tdd_state_result.score}
    Alignment Score: #{Float.round(alignment_result.score, 2)}
    Overall Score: #{Float.round(overall_score, 2)} (required: >= #{@required_overall_score})

    Errors:
    #{Enum.map_join(errors, "\n", fn error -> "- #{String.trim(error)}" end)}

    Please fix the test file to address these quality issues.
    """
  end

  # TDD state checking - validates all tests are failing when no implementation exists

  defp check_tdd_state(_test_run, tdd_mode: false), do: %{score: 1.0, errors: []}

  defp check_tdd_state(%{stats: %{failures: failures, passes: 0}}, tdd_mode: true)
       when failures > 0 do
    %{score: 1.0, errors: []}
  end

  defp check_tdd_state(%{stats: %{passes: passes}}, tdd_mode: true) when passes > 0 do
    %{
      score: 0.0,
      errors: [
        """
        #{passes} test(s) are passing, but these tests are written against a non-existent module.
        Ensure you are not calling components of the module, or non-applicable functions.
        All tests should be failing in TDD mode before implementation exists.
        """
      ]
    }
  end

  defp check_tdd_state(%{stats: %{failures: 0, passes: 0}}, tdd_mode: true) do
    %{score: 0.0, errors: ["No tests were executed"]}
  end

  # Spec alignment checking using StaticAnalysis.Analyzers.SpecAlignment

  defp run_spec_alignment(scope, component, project, tdd_mode: tdd_mode) do
    %{spec_file: spec_file_path} = Utils.component_files(component, project)

    case StaticAnalysis.run(scope, :spec_alignment, spec_file: spec_file_path) do
      {:ok, problems} ->
        test_problems = Enum.filter(problems, &(&1.category in ["missing_test", "extra_test"]))
        errors = Enum.map(test_problems, & &1.message)

        # In TDD mode, missing tests are expected (no implementation yet)
        errors =
          if tdd_mode,
            do: Enum.reject(errors, &String.contains?(&1, "Missing test")),
            else: errors

        # Score: 1.0 if no problems, decrease by 0.1 per problem (min 0.0)
        score = if Enum.empty?(errors), do: 1.0, else: max(0.0, 1.0 - length(errors) * 0.1)

        %{score: score, errors: errors}

      {:error, reason} ->
        %{score: 0.0, errors: [reason]}
    end
  end
end
