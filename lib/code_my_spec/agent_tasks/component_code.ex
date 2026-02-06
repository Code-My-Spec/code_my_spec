defmodule CodeMySpec.AgentTasks.ComponentCode do
  @moduledoc """
  Consolidated component coding session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the implementation prompt
  - `evaluate/3` - Called by stop hook to run tests and provide feedback
  """

  alias CodeMySpec.{Components, Environments, Rules, Tests, Utils}

  @doc """
  Generate the command/prompt for Claude to implement a component.

  Called by the slash command to build the implementation prompt with:
  - Spec file location
  - Test file location
  - Similar components for patterns
  - Coding rules

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: component, project: project} = session

    with {:ok, rules} <- get_implementation_rules(scope, component) do
      similar_components = Components.list_similar_components(scope, component)
      build_implementation_prompt(project, component, rules, similar_components)
    end
  end

  @doc """
  Evaluate Claude's output by running tests and providing feedback.

  Called by the stop hook after Claude implements the component. This:
  1. Runs the component's test file
  2. Parses test results
  3. Returns success if all tests pass
  4. Returns test failures for Claude to fix

  Returns:
  - {:ok, :valid} if all tests pass
  - {:ok, :invalid, errors} if tests fail (for Claude to fix)
  - {:error, reason} if something went wrong
  """
  def evaluate(_scope, session, _opts \\ []) do
    %{component: component, project: project} = session

    %{test_file: test_file_path, code_file: code_file_path} =
      Utils.component_files(component, project)

    # Check required files exist
    case check_required_files(session, test_file_path, code_file_path) do
      {:error, feedback} ->
        {:ok, :invalid, feedback}

      :ok ->
        case run_tests(test_file_path) do
          {:ok, test_run} ->
            case test_run.stats.failures do
              0 ->
                {:ok, :valid}

              _count ->
                {:ok, :invalid, build_test_failure_feedback(test_run)}
            end

          {:error, {:parse_error, output}} ->
            # Tests couldn't even run (compile error, etc.)
            {:ok, :invalid, build_execution_error_feedback(output)}
        end
    end
  end

  # Private functions

  defp get_implementation_rules(_scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "code")
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_implementation_prompt(project, component, rules, similar_components) do
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)

    %{
      spec_file: spec_file_path,
      code_file: code_file_path,
      test_file: test_file_path
    } = Utils.component_files(component, project)

    similar_components_text = format_similar_components(project, similar_components)

    prompt =
      """
      Generate the implementation for a Phoenix component.

      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Description: #{component.description || "No description provided"}
      Type: #{component.type}

      Spec File: #{spec_file_path}
      Test File: #{test_file_path}

      Implementation Instructions:
      1. Read the spec file to understand the component architecture
      2. Read the test file to understand the expected behavior and any test fixtures
      3. Create all necessary module files following the component spec
      4. Implement all public API functions specified in the spec
      5. Ensure the implementation satisfies the tests
      6. Follow project patterns for similar components
      7. Create schemas, migrations, or supporting code as needed

      Similar Components (for implementation pattern inspiration):
      #{similar_components_text}

      Coding Rules:
      #{rules_text}

      Write the implementation to #{code_file_path}
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

  defp check_required_files(session, test_file_path, code_file_path) do
    {:ok, environment} =
      Environments.create(session.environment_type, working_dir: session[:working_dir])

    missing_files = []

    missing_files =
      if Environments.file_exists?(environment, code_file_path) do
        missing_files
      else
        missing_files ++ [{:code, code_file_path}]
      end

    missing_files =
      if Environments.file_exists?(environment, test_file_path) do
        missing_files
      else
        missing_files ++ [{:test, test_file_path}]
      end

    case missing_files do
      [] ->
        :ok

      files ->
        feedback = format_missing_files_error(files)
        {:error, feedback}
    end
  end

  defp format_missing_files_error(missing_files) do
    file_list =
      Enum.map_join(missing_files, "\n", fn {type, path} -> "- #{type} file: #{path}" end)

    """
    Required files do not exist:

    #{file_list}

    You must write these files before evaluation can proceed.
    Please create the files at the paths shown above.
    """
  end

  defp run_tests(test_file_path) do
    Tests.execute([test_file_path])
  end

  defp build_test_failure_feedback(%{failures: failures, stats: stats}) do
    failure_details =
      Enum.map_join(failures, "\n\n", fn failure ->
        error_detail =
          case failure.error do
            %{message: message} -> "Error: #{message}"
            nil -> "No error details available"
          end

        "#{failure.full_title}\n#{error_detail}"
      end)

    """
    Tests failed: #{stats.failures} of #{stats.tests} tests failed.

    Failures:
    #{failure_details}

    Please fix the implementation to make these tests pass.
    """
  end

  defp build_execution_error_feedback(output) do
    """
    Tests could not run due to an error (likely a compile error):

    #{output}

    Please fix the code so the tests can run.
    """
  end
end
