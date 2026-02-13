defmodule CodeMySpec.AgentTasks.LiveViewTest do
  @moduledoc """
  LiveView test session for Claude Code slash commands.

  Like ComponentTest but specialized for LiveView concerns: mounts the view
  via `live/2`, tests handle_event callbacks, and validates rendered HTML
  structure. Visual validation is handled separately by BDD specs.

  Two main functions:
  - `command/3` - Called by slash command to generate the LiveView test writing prompt
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

  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    with {:ok, test_rules} <- get_test_rules(component) do
      similar_components = Components.list_similar_components(scope, component)
      {:ok, prompt} = build_test_prompt(scope, session, test_rules, similar_components)
      {:ok, TaskMarker.build("LiveViewTest", component.module_name) <> "\n\n" <> prompt}
    end
  end

  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session
    component = ComponentRepository.get_component(scope, component.id)
    requirements = component.requirements || []

    test_reqs =
      Requirements.check_requirements(scope, component, requirements,
        artifact_types: [:tests]
      )

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

  # Private functions

  defp get_test_rules(component) do
    Rules.find_matching_rules(component.type, "test")
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
      Generate LiveView tests for the following component.
      #{tdd_section}

      Use Phoenix.LiveViewTest to mount the view via live/2, test handle_event callbacks,
      and validate rendered HTML structure.

      Tests should be grouped by describe blocks that match the function signature EXACTLY.
      Any blocks that don't match the test assertions in the spec will be rejected and you'll have to redo them.

      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Type: #{component.type}
      Component Description: #{component.description}

      Parent Context Design File: #{parent_spec_file_path}
      Component Design File: #{spec_file_path}

      Similar Components (for test pattern inspiration):
      #{similar_text}

      Test Rules:
      #{test_rules_text}

      Write the test file to #{test_file_path}.

      Focus on:
      - Reading the design files to understand the component architecture and parent context
      - Mounting the LiveView via live/2 and testing mount assigns
      - Testing handle_event callbacks with render_click, render_submit, etc.
      - Validating rendered HTML structure with has_element? and render assertions
      - Creating reusable fixture functions for test data
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
