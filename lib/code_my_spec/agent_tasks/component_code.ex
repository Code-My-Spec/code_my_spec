defmodule CodeMySpec.AgentTasks.ComponentCode do
  @moduledoc """
  Consolidated component coding session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the implementation prompt
  - `evaluate/3` - Called by stop hook to check implementation file exists
  """

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.{Rules, Utils}

  def analyzers, do: [:exunit_stale]

  @doc """
  Generate the command/prompt for Claude to implement a component.

  Called by the slash command to build the implementation prompt with:
  - Spec file location
  - Test file location
  - Coding rules

  Returns {:ok, prompt_text}
  """
  def command(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project

    with {:ok, rules} <- get_implementation_rules(scope, component) do
      {:ok, prompt} = build_implementation_prompt(project, component, rules)
      {:ok, prompt}
    end
  end

  @doc """
  Evaluate Claude's output by checking the code file exists.

  Called by the stop hook after Claude implements the component.

  Returns:
  - {:ok, :valid} if the code file exists
  - {:ok, :invalid, feedback} if the code file is missing
  """
  def evaluate(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project
    component = ComponentRepository.get_component(scope, component.id)

    code_reqs = Requirements.check_artifact_requirements(scope, component, :code)

    unsatisfied = Enum.filter(code_reqs, &(not &1.satisfied))

    req_feedback =
      if Enum.empty?(unsatisfied) do
        nil
      else
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Code requirements not met:"
        )
      end

    problem_feedback = ProblemFeedback.for_code_task(scope, component, project)
    ProblemFeedback.combine(req_feedback, problem_feedback)
  end

  def orchestrate(node) do
    "Spawn a @code-writer sub-agent to call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  # Private functions

  defp get_implementation_rules(scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "code", scope.environment.cwd)
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_implementation_prompt(project, component, rules) do
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)

    %{
      spec_file: spec_file_path,
      code_file: code_file_path,
      test_file: test_file_path
    } = Utils.component_files(component, project)

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
      6. Create schemas, migrations, or supporting code as needed

      Coding Rules:
      #{rules_text}

      Write the implementation to #{code_file_path}
      """

    {:ok, prompt}
  end
end
