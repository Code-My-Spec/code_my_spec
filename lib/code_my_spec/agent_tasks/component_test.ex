defmodule CodeMySpec.AgentTasks.ComponentTest do
  @moduledoc """
  Consolidated component test session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the test writing prompt
  - `evaluate/3` - Called by stop hook to check test requirements are satisfied
  """

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components
  alias CodeMySpec.Components.{Component, ComponentRepository}
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Rules
  alias CodeMySpec.Utils

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
      {:ok, prompt} = build_test_prompt(scope, session, test_rules, similar_components)
      {:ok, TaskMarker.build("ComponentTest", component.module_name) <> "\n\n" <> prompt}
    end
  end

  @doc """
  Evaluate whether the test file was written correctly.

  Called by the stop hook after Claude writes tests. Checks that:
  1. The test file exists
  2. No blocking problems (compilation errors, credo, spec alignment)

  Test failures are filtered out — failing tests are expected in TDD mode
  when the implementation doesn't exist yet.

  Returns:
  - {:ok, :valid} if the test file exists with no blocking problems
  - {:ok, :invalid, feedback} if the test file is missing or has blocking problems
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session
    component = ComponentRepository.get_component(scope, component.id)

    # Check test-artifact requirements (test_file, test_spec_alignment)
    test_reqs = Requirements.check_artifact_requirements(scope, component, :tests)

    unsatisfied = Enum.filter(test_reqs, &(not &1.satisfied))

    req_feedback =
      if Enum.empty?(unsatisfied) do
        nil
      else
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Test requirements not met:"
        )
      end

    problem_feedback = ProblemFeedback.for_test_task(scope, component, project)
    ProblemFeedback.combine(req_feedback, problem_feedback)
  end

  # Private functions - command

  defp get_test_rules(_scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "test")
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_test_prompt(scope, session, test_rules, similar_components) do
    %{project: project, component: component} = session
    test_rules_text = Enum.map_join(test_rules, "\n\n", & &1.content)
    similar_text = format_similar_components(project, similar_components)

    %{spec_file: spec_file_path, test_file: test_file_path} =
      Utils.component_files(component, project)

    implementation_exists = implementation_exists?(scope, component)

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

  defp implementation_exists?(scope, component) do
    component = ComponentRepository.get_component(scope, component.id)
    requirements = component.requirements || []

    code_reqs =
      Requirements.check_requirements(scope, component, requirements,
        artifact_types: [:code],
        include: ["implementation_file"]
      )

    Enum.any?(code_reqs, & &1.satisfied)
  end
end
