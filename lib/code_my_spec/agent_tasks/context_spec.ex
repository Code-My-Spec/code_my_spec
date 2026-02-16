defmodule CodeMySpec.AgentTasks.ContextSpec do
  @moduledoc """
  Consolidated context spec session for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the prompt for Claude
  - `evaluate/3` - Called by stop hook to validate output and provide feedback
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components
  alias CodeMySpec.Components.{ComponentRepository, Registry}
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
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
  - Similar components

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: component} = session

    with {:ok, rules} <- get_design_rules(scope),
         similar <- Components.list_similar_components(scope, component),
         stories <- Stories.list_component_stories(scope, component.id),
         {:ok, prompt} <- build_spec_prompt(session, rules, stories, similar) do
      {:ok, TaskMarker.build("ContextSpec", component.module_name) <> "\n\n" <> prompt}
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
  def evaluate(scope, session, _opts \\ []) do
    %{component: component, project: project} = session
    component = ComponentRepository.get_component(scope, component.id)

    spec_reqs = check_artifact_requirements(scope, component, :specification)
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
        with {:ok, spec_content} <- read_spec_file(scope, session),
             {:ok, document} <- validate_document(spec_content),
             {:ok, _paths} <- create_child_spec_files(scope, session, document.sections) do
          {:ok, :valid}
        end
    end
  end

  # Private functions

  defp check_artifact_requirements(scope, component, artifact_type) do
    requirements = component.requirements || []

    case Requirements.check_requirements(scope, component, requirements,
           artifact_types: [artifact_type]
         ) do
      [] ->
        Registry.get_requirements_for_type(component.type)
        |> Enum.filter(&(&1.artifact_type == artifact_type))
        |> then(&Requirements.check_requirements(scope, component, &1, []))

      results ->
        results
    end
  end

  defp get_design_rules(_scope) do
    rules = Rules.find_matching_rules("context", "design")
    {:ok, rules}
  end

  defp build_spec_prompt(session, rules, stories, similar_components) do
    %{project: project, component: context} = session
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)
    stories_text = format_stories(stories)
    similar_text = format_similar_components(project, similar_components)
    document_spec = DocumentSpecProjector.project_spec("context_spec")
    %{spec_file: spec_file_path} = Utils.component_files(context, project)

    prompt = """
    Your task is to generate a specification for a Phoenix bounded context.

    # Project

    Project: #{project.name}
    Project Description: #{project.description}

    # Bounded context

    Context Name: #{context.name}
    Context Description: #{context.description || "No description provided"}
    Type: #{context.type}

    # User Stories this context satisfies
    #{stories_text}

    # Similar Components
    #{similar_text}

    # How to write the document
    #{document_spec}

    # Design Rules
    #{rules_text}

    Please write the specification to: #{spec_file_path}
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
         Design: #{files.spec_file}
         Implementation: #{files.code_file}
         Test: #{files.test_file}
      """
      |> String.trim()
    end)
  end

  defp format_stories([]), do: "No user stories provided"

  defp format_stories(stories) do
    stories
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {story, index} ->
      acceptance_criteria =
        case story.acceptance_criteria do
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

  defp read_spec_file(scope, session) do
    %{spec_file: path} = Utils.component_files(session.component, session.project)

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

  defp create_child_spec_files(scope, _session, %{"components" => components})
       when is_list(components) do
    results = Enum.map(components, &maybe_create_child_spec(scope, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, path} -> path end)}
      {:error, reason} -> {:error, "Failed to create child spec files: #{inspect(reason)}"}
    end
  end

  defp create_child_spec_files(_scope, _session, _sections), do: {:ok, []}

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
end
