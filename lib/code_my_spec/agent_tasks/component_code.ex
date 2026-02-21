defmodule CodeMySpec.AgentTasks.ComponentCode do
  @moduledoc """
  Consolidated component coding session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the implementation prompt
  - `evaluate/3` - Called by stop hook to check implementation file exists
  """

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.{Rules, Utils}

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
      {:ok, prompt} = build_implementation_prompt(project, component, rules, similar_components)
      {:ok, TaskMarker.build("ComponentCode", component.module_name) <> "\n\n" <> prompt}
    end
  end

  @doc """
  Evaluate Claude's output by checking the code file exists.

  Called by the stop hook after Claude implements the component.

  Returns:
  - {:ok, :valid} if the code file exists
  - {:ok, :invalid, feedback} if the code file is missing
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session
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
end
