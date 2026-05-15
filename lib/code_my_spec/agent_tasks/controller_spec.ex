defmodule CodeMySpec.AgentTasks.ControllerSpec do
  @moduledoc """
  Agent task that generates a Phoenix controller specification.

  Produces specs for Phoenix controllers (action functions, params, render
  targets, dependencies). Mirrors the ContextSpec / LiveContextSpec /
  LiveViewSpec pattern — `command/2` builds the spec-writing prompt,
  `evaluate/2` validates the resulting spec against artifact requirements.
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Rules
  alias CodeMySpec.Utils

  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project

    with {:ok, rules} <- get_design_rules(scope, component) do
      build_spec_prompt(scope, component, project, rules)
    end
  end

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project
    component = ComponentRepository.get_component(scope, component.id)

    spec_reqs = Requirements.check_artifact_requirements(scope, component, :specification)
    satisfied_count = Enum.count(spec_reqs, & &1.satisfied)
    total = length(spec_reqs)
    unsatisfied = Enum.filter(spec_reqs, &(not &1.satisfied))

    Logger.info(
      "[ControllerSpec] evaluate #{component.module_name}: #{satisfied_count}/#{total} specification requirements pass"
    )

    req_feedback =
      if Enum.empty?(unsatisfied) do
        nil
      else
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Controller spec requirements not met:"
        )
      end

    problem_feedback = ProblemFeedback.for_spec_task(scope, component, project)
    ProblemFeedback.combine(req_feedback, problem_feedback)
  end

  def orchestrate(_node) do
    "Write the spec file for a Phoenix controller — actions, params, render " <>
      "targets, dependencies. Use when the controller has no spec yet. " <>
      "Sub-agent: spawn @spec-writer."
  end

  defp get_design_rules(scope, component) do
    rules = Rules.find_matching_rules(component.type, "design", scope.environment)
    {:ok, rules}
  end

  defp build_spec_prompt(scope, component, project, rules) do
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)
    document_spec = DocumentSpecProjector.project_spec("controller_spec")
    %{spec_file: spec_file_path} = Utils.component_files(component, project)

    parent_component_clause =
      case Map.get(component, :parent_component, nil) do
        %Component{} = parent ->
          %{spec_file: parent_spec_path} = Utils.component_files(parent, project)
          "Parent Context Design File: #{parent_spec_path}"

        _ ->
          ""
      end

    environment = scope.environment

    %{code_file: code_file, test_file: test_file} =
      Utils.component_files(component, project)

    existing_implementation_clause =
      if Environments.file_exists?(environment, code_file) do
        "Existing Implementation: #{code_file}"
      else
        "The implementation doesn't exist yet."
      end

    existing_test_clause =
      if Environments.file_exists?(environment, test_file) do
        "Existing tests: #{test_file}"
      else
        "The tests don't exist yet."
      end

    prompt = """
    Your task is to generate a specification for a Phoenix controller —
    an HTTP request handler that maps routes to action functions, calls
    bounded contexts, and renders responses (HTML, JSON, redirect).

    # Project

    Project: #{project.name}
    Project Description: #{project.description}

    # Controller

    Controller Name: #{component.name}
    Controller Description: #{component.description || "No description provided"}
    Type: #{component.type}
    #{parent_component_clause}
    #{existing_implementation_clause}
    #{existing_test_clause}

    # How to write the document
    #{document_spec}

    # Design Rules
    #{rules_text}

    Please write the specification to: #{spec_file_path}
    """

    {:ok, prompt}
  end
end
