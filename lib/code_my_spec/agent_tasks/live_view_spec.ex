defmodule CodeMySpec.AgentTasks.LiveViewSpec do
  @moduledoc """
  Agent task that generates a LiveView specification.

  Like ComponentSpec but for UI components — produces specs following the UI spec format:
  route, params, child components, user interactions, dependencies, and a structural
  Design section describing layout structure, DaisyUI component choices, and responsive
  behavior in prose.

  Two main functions:
  - `command/3` - Generates the spec-writing prompt including UI format guidance
  - `evaluate/3` - Validates the spec via specification requirements
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Rules
  alias CodeMySpec.Utils

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    with {:ok, rules} <- get_design_rules(scope, component),
         {:ok, prompt} <- build_spec_prompt(scope, session, rules) do
      {:ok, TaskMarker.build("LiveViewSpec", component.module_name) <> "\n\n" <> prompt}
    end
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session
    component = ComponentRepository.get_component(scope, component.id)

    spec_reqs = Requirements.check_artifact_requirements(scope, component, :specification)
    satisfied_count = Enum.count(spec_reqs, & &1.satisfied)
    total = length(spec_reqs)
    unsatisfied = Enum.filter(spec_reqs, &(not &1.satisfied))

    Logger.info(
      "[LiveViewSpec] evaluate #{component.module_name}: #{satisfied_count}/#{total} specification requirements pass"
    )

    req_feedback =
      if Enum.empty?(unsatisfied) do
        nil
      else
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Spec requirements not met:"
        )
      end

    problem_feedback = ProblemFeedback.for_spec_task(scope, component, project)
    ProblemFeedback.combine(req_feedback, problem_feedback)
  end

  def orchestrate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate(__MODULE__, scope, session, opts)
  end

  def orchestrate_evaluate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate_evaluate(__MODULE__, scope, session, opts)
  end

  # Private functions

  defp get_design_rules(_scope, %{type: nil}), do: {:error, :invalid_component_type}
  defp get_design_rules(_scope, %{type: ""}), do: {:error, :invalid_component_type}

  defp get_design_rules(scope, component) do
    Rules.find_matching_rules(component.type, "design", scope.environment.cwd)
    |> case do
      rules when is_list(rules) -> {:ok, rules}
    end
  end

  defp build_spec_prompt(scope, session, rules) do
    %{project: project, component: component} = session
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)
    document_spec = DocumentSpecProjector.project_spec(component.type)
    %{spec_file: spec_file_path} = Utils.component_files(component, project)

    parent_component_clause =
      case Map.get(component, :parent_component, nil) do
        %Component{} = parent_component ->
          %{spec_file: parent_spec_file_path} =
            Utils.component_files(parent_component, project)

          "Parent Component Spec: #{parent_spec_file_path}"

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

    similar_components_clause = build_similar_components_clause(scope, component)

    prompt =
      """
      Generate a LiveView spec for the following.
      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Description: #{component.description || "No description provided"}
      Type: #{component.type}
      #{parent_component_clause}
      #{existing_implementation_clause}
      #{existing_test_clause}
      #{similar_components_clause}

      Design Rules:
      #{rules_text}

      Document Specifications:
      #{document_spec}

      Write the document to #{spec_file_path}.
      """

    {:ok, prompt}
  end

  defp build_similar_components_clause(scope, component) do
    case Components.list_similar_components(scope, component) do
      [] ->
        ""

      similar_components ->
        names = Enum.map_join(similar_components, ", ", & &1.name)
        "Similar Components (for pattern inspiration): #{names}"
    end
  end
end
