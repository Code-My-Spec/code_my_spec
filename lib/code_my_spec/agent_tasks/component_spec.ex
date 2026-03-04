defmodule CodeMySpec.AgentTasks.ComponentSpec do
  @moduledoc """
  Consolidated component spec session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the prompt for Claude
  - `evaluate/3` - Called by stop hook to validate output and provide feedback
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Rules
  alias CodeMySpec.Utils

  @doc """
  Generate the command/prompt for Claude to create a component spec.

  Called by the slash command to build the initial prompt with:
  - Design rules
  - Document specifications
  - Project context
  - Component details

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    with {:ok, rules} <- get_design_rules(scope, component),
         {:ok, prompt} <- build_spec_prompt(scope, session, rules) do
      {:ok, TaskMarker.build("ComponentSpec", component.module_name) <> "\n\n" <> prompt}
    end
  end

  @doc """
  Evaluate Claude's output and provide feedback if needed.

  Called by the stop hook after Claude generates the spec. This:
  1. Reads the generated spec file
  2. Validates it against the document schema
  3. Returns success if valid
  4. Returns validation errors if invalid (for Claude to fix)

  Returns:
  - {:ok, :valid} if the spec passes validation
  - {:ok, :invalid, errors} if the spec needs revision
  - {:error, reason} if something went wrong
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session

    if is_nil(component) do
      {:error, "No component found for session (module: #{session.component_module_name})"}
    else
      evaluate_component(scope, component, project)
    end
  end

  def orchestrate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate(__MODULE__, scope, session, opts)
  end

  def orchestrate_evaluate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate_evaluate(__MODULE__, scope, session, opts)
  end

  defp evaluate_component(scope, component, project) do
    component = ComponentRepository.get_component(scope, component.id)

    spec_reqs = Requirements.check_artifact_requirements(scope, component, :specification)
    satisfied_count = Enum.count(spec_reqs, & &1.satisfied)
    total = length(spec_reqs)
    unsatisfied = Enum.filter(spec_reqs, &(not &1.satisfied))

    Logger.info(
      "[ComponentSpec] evaluate #{component.module_name}: #{satisfied_count}/#{total} specification requirements pass"
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

  # Private functions

  defp get_design_rules(scope, component) do
    component_type = component.type

    Rules.find_matching_rules(component_type, "design", scope.environment.cwd)
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

          "Parent Context Design File: #{parent_spec_file_path}"

        _ ->
          ""
      end

    environment = scope.environment

    %{code_file: code_file, test_file: test_file} =
      Utils.component_files(component, project)

    existing_implementation_clause =
      if Environments.file_exists?(environment, code_file) do
        "Existing Implementation: #{code_file}."
      else
        "The implementation doesn't exist yet."
      end

    existing_test_clause =
      if Environments.file_exists?(environment, test_file) do
        "Existing tests: #{test_file}"
      else
        "The tests don't exist yet."
      end

    prompt =
      """
      Generate a Phoenix component spec for the following.
      Project: #{project.name}
      Project Description: #{project.description}
      Component Name: #{component.name}
      Component Description: #{component.description || "No description provided"}
      Type: #{component.type}
      #{parent_component_clause}
      #{existing_implementation_clause}
      #{existing_test_clause}

      Design Rules:
      #{rules_text}

      Document Specifications:
      #{document_spec}

      Write the document to #{spec_file_path}.
      """

    {:ok, prompt}
  end
end
