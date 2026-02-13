defmodule CodeMySpec.AgentTasks.LiveViewCode do
  @moduledoc """
  LiveView coding session for Claude Code slash commands.

  Like ComponentCode but specialized for LiveView modules. The command prompt
  references a resources directory for progressive-disclosure LiveView guidance
  rather than embedding it directly. The evaluate step checks code artifact
  requirements (and will eventually also handle screenshot feedback).

  Two main functions:
  - `command/3` - Called by slash command to generate the LiveView implementation prompt
  - `evaluate/3` - Called by stop hook to check implementation requirements
  """

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.{Rules, Utils}

  @doc """
  Generate the command/prompt for Claude to implement a LiveView.

  Called by the slash command to build the implementation prompt with:
  - Spec file location
  - Test file location
  - Similar components for patterns
  - Coding rules
  - Resources directory for progressive-disclosure LiveView guidance

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: component, project: project} = session

    with {:ok, rules} <- get_implementation_rules(component) do
      similar_components = Components.list_similar_components(scope, component)
      {:ok, prompt} = build_implementation_prompt(project, component, rules, similar_components)
      {:ok, TaskMarker.build("LiveViewCode", component.module_name) <> "\n\n" <> prompt}
    end
  end

  @doc """
  Evaluate Claude's LiveView implementation by checking code artifact requirements.

  Called by the stop hook after Claude implements the LiveView.

  Returns:
  - {:ok, :valid} if all code requirements are satisfied
  - {:ok, :invalid, feedback} if any code requirements are unsatisfied
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session
    component = ComponentRepository.get_component(scope, component.id)
    requirements = component.requirements || []

    code_reqs =
      Requirements.check_requirements(scope, component, requirements,
        artifact_types: [:code]
      )

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

  defp get_implementation_rules(component) do
    Rules.find_matching_rules(component.type, "code")
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
      Generate the implementation for a Phoenix LiveView module.

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
      3. Read the resources directory index (resources/README.md) for LiveView-specific guidance
      4. Consult topic-specific resources as needed during implementation
      5. Create all necessary module files following the component spec
      6. Implement all public API functions specified in the spec
      7. Ensure the implementation satisfies the tests
      8. Follow project patterns for similar components

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
