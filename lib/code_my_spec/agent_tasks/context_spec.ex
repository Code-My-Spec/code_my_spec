defmodule CodeMySpec.AgentTasks.ContextSpec do
  @moduledoc """
  Consolidated context spec session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the prompt for Claude
  - `evaluate/3` - Called by stop hook to validate output and provide feedback
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Rules
  alias CodeMySpec.Stories
  alias CodeMySpec.Utils

  @doc """
  Generate the command/prompt for Claude to create a context spec.

  Called by the slash command to build the initial prompt with:
  - Design rules
  - Document specifications
  - Project context
  - Context details
  - User stories

  Returns {:ok, prompt_text}
  """
  def command(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project

    with {:ok, rules} <- get_design_rules(scope),
         stories <- Stories.list_component_stories(scope, component.id) do
      diagnostics = previous_validation_diagnostics(scope, component, project)
      build_spec_prompt(component, project, rules, stories, diagnostics)
    end
  end

  @doc """
  Evaluate Claude's output and provide feedback if needed.

  Called by the stop hook after Claude generates the spec. This:
  1. Reads the generated spec file
  2. Validates it against the context_spec document schema
  3. Returns success if valid
  4. Returns validation errors if invalid (for Claude to fix)

  Returns:
  - {:ok, :valid} if the spec passes validation
  - {:ok, :invalid, errors} if the spec needs revision
  - {:error, reason} if something went wrong
  """
  def evaluate(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project
    component = ComponentRepository.get_component(scope, component.id)

    spec_reqs = Requirements.check_artifact_requirements(scope, component, :specification)
    satisfied_count = Enum.count(spec_reqs, & &1.satisfied)
    total = length(spec_reqs)
    unsatisfied = Enum.filter(spec_reqs, &(not &1.satisfied))

    Logger.info(
      "[ContextSpec] evaluate #{component.module_name}: #{satisfied_count}/#{total} specification requirements pass"
    )

    req_feedback =
      if Enum.empty?(unsatisfied) do
        nil
      else
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Context spec requirements not met:"
        )
      end

    problem_feedback = ProblemFeedback.for_spec_task(scope, component, project)

    case ProblemFeedback.combine(req_feedback, problem_feedback) do
      {:ok, :invalid, _feedback} = invalid ->
        invalid

      {:ok, :valid} ->
        # Requirements and problems pass — create child spec stubs (won't overwrite existing)
        with {:ok, spec_content} <- read_spec_file(scope, component, project),
             {:ok, document} <- validate_document(spec_content),
             {:ok, _paths} <- create_child_spec_files(scope, document.sections) do
          {:ok, :valid}
        end
    end
  end

  def orchestrate(node) do
    "Spawn a @spec-writer sub-agent to call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  # Private functions

  defp get_design_rules(scope) do
    rules = Rules.find_matching_rules("context", "design", scope.environment)
    {:ok, rules}
  end

  defp build_spec_prompt(context, project, rules, stories, diagnostics) do
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)
    stories_text = format_stories(stories)
    document_spec = DocumentSpecProjector.project_spec("context_spec")
    %{spec_file: spec_file_path} = Utils.component_files(context, project)

    prompt = """
    Your task is to generate a specification for a Phoenix bounded context.
    #{diagnostics}
    # Project

    Project: #{project.name}
    Project Description: #{project.description}

    # Bounded context

    Context Name: #{context.name}
    Context Description: #{context.description || "No description provided"}
    Type: #{context.type}

    # User Stories this context satisfies
    #{stories_text}

    # How to write the document
    #{document_spec}

    # Design Rules
    #{rules_text}

    Please write the specification to: #{spec_file_path}
    """

    {:ok, prompt}
  end

  defp previous_validation_diagnostics(scope, component, project) do
    component = ComponentRepository.get_component(scope, component.id)
    spec_reqs = Requirements.check_artifact_requirements(scope, component, :specification)
    unsatisfied = Enum.filter(spec_reqs, &(not &1.satisfied))

    file_missing? = Enum.any?(unsatisfied, &(&1.name == "spec_file"))

    cond do
      Enum.empty?(unsatisfied) -> ""
      file_missing? -> ""
      true -> format_diagnostics(unsatisfied, component, project)
    end
  end

  defp format_diagnostics(unsatisfied, component, project) do
    %{spec_file: spec_file_path} = Utils.component_files(component, project)

    feedback =
      RequirementsFormatter.format_unsatisfied(unsatisfied,
        context: "Previous validation failed for #{spec_file_path}:"
      )

    """

    # Previous validation diagnostics

    Re-read the spec file at the path above and revise it to address each
    diagnostic below before re-writing the spec.

    #{Problems.truncate_to_cap(feedback)}
    """
  end

  defp format_stories([]), do: "No user stories provided"

  defp format_stories(stories) do
    stories
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {story, index} ->
      acceptance_criteria =
        case criteria_descriptions(story) do
          [] -> "  None specified"
          criteria -> Enum.map_join(criteria, "\n", &"  - #{&1}")
        end

      """
      Story #{index}: #{story.title}
      Description: #{story.description}
      Acceptance Criteria:
      #{acceptance_criteria}
      """
      |> String.trim()
    end)
  end

  defp read_spec_file(scope, component, project) do
    %{spec_file: path} = Utils.component_files(component, project)

    environment = scope.environment

    case Environments.read_file(environment, path) do
      {:ok, content} ->
        if String.trim(content) == "" do
          {:error, "Spec file is empty"}
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:error, "Spec file not found at #{path}"}

      {:error, error} ->
        {:error, "Failed to read file #{path}: #{inspect(error)}"}
    end
  end

  defp validate_document(spec_content) do
    Documents.create_dynamic_document(spec_content, "context_spec")
  end

  defp create_child_spec_files(scope, %{"components" => components})
       when is_list(components) do
    results = Enum.map(components, &maybe_create_child_spec(scope, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, path} -> path end)}
      {:error, reason} -> {:error, "Failed to create child spec files: #{inspect(reason)}"}
    end
  end

  defp create_child_spec_files(_scope, _sections), do: {:ok, []}

  defp maybe_create_child_spec(scope, %{module_name: module_name, description: description}) do
    %{spec_file: file_path} = Utils.component_files(module_name)

    if Environments.file_exists?(scope.environment, file_path) do
      {:ok, file_path}
    else
      content = build_child_spec_content(module_name, description)

      case Environments.write_file(scope.environment, file_path, content) do
        :ok -> {:ok, file_path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_child_spec_content(module_name, description) do
    """
    # #{module_name}

    #{description}
    """
  end

  defp criteria_descriptions(story) do
    case story.criteria do
      criteria when is_list(criteria) and criteria != [] ->
        Enum.map(criteria, & &1.description)

      _ ->
        story.acceptance_criteria || []
    end
  end
end
