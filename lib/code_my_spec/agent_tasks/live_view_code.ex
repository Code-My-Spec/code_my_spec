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
  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.{Rules, Stories, Utils}

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
      bdd_spec_files = get_bdd_spec_files(scope, component)

      {:ok, prompt} =
        build_implementation_prompt(project, component, rules, similar_components, bdd_spec_files)

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
      Requirements.check_requirements(scope, component, requirements, artifact_types: [:code])

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
    spex_feedback = check_bdd_specs(scope, component)

    [req_feedback, problem_feedback, spex_feedback]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> {:ok, :valid}
      feedbacks -> {:ok, :invalid, Enum.join(feedbacks, "\n\n")}
    end
  end

  # Private functions - BDD specs

  defp get_bdd_spec_files(scope, component) do
    env = scope.environment

    Stories.list_component_stories(scope, component.id)
    |> Enum.flat_map(fn story -> BddSpecs.list_specs_for_story(env, story.id) end)
    |> Enum.map(& &1.file_path)
    |> Enum.uniq()
  end

  defp check_bdd_specs(scope, component) do
    spec_files = get_bdd_spec_files(scope, component)

    if Enum.empty?(spec_files) do
      nil
    else
      run_bdd_specs(spec_files, scope.environment.cwd)
    end
  end

  defp run_bdd_specs(spec_files, cwd) do
    case BddSpecs.run_specs(spec_files, project_root: cwd, quiet: true) do
      {:ok, failures, exit_code} when exit_code != 0 or failures != [] ->
        failure_list =
          Enum.map_join(failures, "\n", fn f -> "- #{f.spex}: #{f.scenario}" end)

        """
        BDD specs are failing for stories satisfied by this component:

        #{failure_list}

        Fix the implementation so these specs pass.
        """

      {:ok, _failures, _exit_code} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  # Private functions - Rules and prompt building

  defp get_implementation_rules(component) do
    Rules.find_matching_rules(component.type, "code")
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_implementation_prompt(project, component, rules, similar_components, bdd_spec_files) do
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)

    %{
      spec_file: spec_file_path,
      code_file: code_file_path,
      test_file: test_file_path
    } = Utils.component_files(component, project)

    similar_components_text = format_similar_components(project, similar_components)
    bdd_spec_text = format_bdd_spec_instructions(bdd_spec_files)

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
      #{bdd_spec_text}

      Similar Components (for implementation pattern inspiration):
      #{similar_components_text}

      Coding Rules:
      #{rules_text}

      Write the implementation to #{code_file_path}
      """

    {:ok, prompt}
  end

  defp format_bdd_spec_instructions([]), do: ""

  defp format_bdd_spec_instructions(bdd_spec_files) do
    file_list = Enum.map_join(bdd_spec_files, "\n", fn f -> "  - #{f}" end)

    """

    BDD Acceptance Specs:
    This component satisfies user stories with BDD specs. After the unit tests
    pass, also run these BDD specs and iterate until they pass:
    #{file_list}

    Run them with: mix spex <file_path>
    """
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
