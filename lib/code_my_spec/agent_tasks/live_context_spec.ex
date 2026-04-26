defmodule CodeMySpec.AgentTasks.LiveContextSpec do
  @moduledoc """
  Agent task that generates a live context specification.

  A live context is a UI grouping of related LiveViews and LiveComponents
  under a shared namespace (e.g., UserLive containing UserLive.Index,
  UserLive.Show, UserLive.FormComponent).

  Follows the ContextSpec pattern:
  - `command/3` - Generates the spec-writing prompt
  - `evaluate/3` - Validates spec and creates child spec stubs from both
    the LiveViews and Components sections
  """

  require Logger

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Documents
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter

  alias CodeMySpec.Rules
  alias CodeMySpec.Utils

  @doc """
  Generate the command/prompt for Claude to create a live context spec.

  Returns {:ok, prompt_text}
  """
  def command(scope, task) do
    component = Components.get_component!(scope, task.component_id)
    project = scope.active_project

    with {:ok, rules} <- get_design_rules(scope),
         similar <- Components.list_similar_components(scope, component) do
      build_spec_prompt(component, project, rules, similar)
    end
  end

  @doc """
  Evaluate Claude's output and provide feedback if needed.

  Validates the spec, then creates child spec stubs from both the LiveViews
  and Components sections.

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
      "[LiveContextSpec] evaluate #{component.module_name}: #{satisfied_count}/#{total} specification requirements pass"
    )

    req_feedback =
      if Enum.empty?(unsatisfied) do
        nil
      else
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Live context spec requirements not met:"
        )
      end

    problem_feedback = ProblemFeedback.for_spec_task(scope, component, project)

    case ProblemFeedback.combine(req_feedback, problem_feedback) do
      {:ok, :invalid, _feedback} = invalid ->
        invalid

      {:ok, :valid} ->
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
    rules = Rules.find_matching_rules("live_context", "design", scope.environment.cwd)
    {:ok, rules}
  end

  defp build_spec_prompt(component, project, rules, similar_components) do
    rules_text = Enum.map_join(rules, "\n\n", & &1.content)
    similar_text = format_similar_components(project, similar_components)
    document_spec = DocumentSpecProjector.project_spec("live_context_spec")
    %{spec_file: spec_file_path} = Utils.component_files(component, project)

    prompt = """
    Your task is to generate a specification for a Phoenix live context —
    a UI grouping of related LiveViews and LiveComponents under a shared namespace.

    # Project

    Project: #{project.name}
    Project Description: #{project.description}

    # Live Context

    Name: #{component.name}
    Description: #{component.description || "No description provided"}
    Type: #{component.type}

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
      """
      |> String.trim()
    end)
  end

  defp read_spec_file(scope, component, project) do
    %{spec_file: path} = Utils.component_files(component, project)

    case Environments.read_file(scope.environment, path) do
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
    Documents.create_dynamic_document(spec_content, "live_context_spec")
  end

  defp create_child_spec_files(scope, sections) do
    liveview_children = extract_children_from_section(sections, "liveviews")
    component_children = extract_children_from_section(sections, "components")
    all_children = liveview_children ++ component_children

    results = Enum.map(all_children, &maybe_create_child_spec(scope, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, path} -> path end)}
      {:error, reason} -> {:error, "Failed to create child spec files: #{inspect(reason)}"}
    end
  end

  defp extract_children_from_section(sections, _key) when is_list(sections) do
    []
  end

  defp extract_children_from_section(sections, key) when is_map(sections) do
    case Map.get(sections, key) do
      children when is_list(children) ->
        Enum.filter(children, &match?(%{module_name: _, description: _}, &1))

      _ ->
        []
    end
  end

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
