defmodule CodeMySpec.AgentTasks.ContextDesignReview do
  @moduledoc """
  Context design review agent task for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the review prompt for Claude
  - `evaluate/3` - Called by stop hook to validate the review document
  """

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.{Components, Documents, Documents.DocumentSpecProjector, Environments, Stories, Utils}

  @doc """
  Generate the command/prompt for Claude to review a context design.

  Called by the slash command to build the review prompt with:
  - Context and child component design files
  - User stories to verify alignment
  - Project context
  - Review document specification

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{component: context_component, project: project} = session

    with {:ok, context_spec_path} <- get_context_spec_path(context_component, project),
         {:ok, child_spec_paths} <- get_child_spec_paths(scope, context_component, project),
         {:ok, stories} <- get_user_stories(scope, context_component),
         {:ok, review_file_path} <- calculate_review_file_path(context_spec_path),
         {:ok, prompt} <-
           build_review_prompt(
             project,
             context_component,
             context_spec_path,
             child_spec_paths,
             stories,
             review_file_path
           ) do
      {:ok, TaskMarker.build("ContextDesignReview", context_component.module_name) <> "\n\n" <> prompt}
    end
  end

  @doc """
  Evaluate Claude's review output and provide feedback if needed.

  Called by the stop hook after Claude generates the review. This:
  1. Reads the generated review file
  2. Validates it against the design_review document schema
  3. Returns success if valid
  4. Returns validation errors if invalid (for Claude to fix)

  Returns:
  - {:ok, :valid} if the review passes validation
  - {:ok, :invalid, errors} if the review needs revision
  - {:error, reason} if something went wrong
  """
  def evaluate(scope, session, _opts \\ []) do
    %{component: context_component, project: project} = session

    with {:ok, context_spec_path} <- get_context_spec_path(context_component, project),
         {:ok, review_file_path} <- calculate_review_file_path(context_spec_path),
         {:ok, review_content} <- read_review_file(scope, review_file_path),
         {:ok, _document} <- validate_document(review_content) do
      {:ok, :valid}
    else
      {:error, validation_errors} when is_binary(validation_errors) ->
        {:ok, :invalid, build_revision_feedback(validation_errors)}
    end
  end

  # Private functions - Data extraction

  defp get_context_spec_path(context_component, project) do
    %{spec_file: spec_file_path} = Utils.component_files(context_component, project)
    {:ok, spec_file_path}
  end

  defp get_child_spec_paths(scope, context_component, project) do
    child_components = Components.list_child_components(scope, context_component.id)

    child_paths =
      Enum.map(child_components, fn child ->
        %{spec_file: spec_file_path} = Utils.component_files(child, project)
        {child.name, child.type, spec_file_path}
      end)

    {:ok, child_paths}
  end

  defp get_user_stories(scope, context_component) do
    stories = Stories.list_component_stories(scope, context_component.id)
    {:ok, stories}
  end

  defp calculate_review_file_path(context_spec_path) do
    # Context spec path: "docs/spec/code_my_spec/sessions.spec.md"
    # Review file path: "docs/spec/code_my_spec/sessions/design_review.md"
    review_path = String.replace_suffix(context_spec_path, ".spec.md", "/design_review.md")
    {:ok, review_path}
  end

  # Private functions - Prompt building

  defp build_review_prompt(
         project,
         context_component,
         context_spec_path,
         child_spec_paths,
         stories,
         review_file_path
       ) do
    document_spec = DocumentSpecProjector.project_spec("design_review")

    prompt = """
    # Context Design Review

    Review the architecture of a Phoenix context and its child components.

    ## Project

    **Project:** #{project.name}
    **Description:** #{project.description || "No description provided"}

    ## Context Being Reviewed

    **Name:** #{context_component.name}
    **Module:** #{context_component.module_name}
    **Type:** #{context_component.type}
    **Description:** #{context_component.description || "No description provided"}

    ## Spec Files to Review

    ### Context Spec
    #{context_spec_path}

    ### Child Component Specs
    #{format_child_spec_paths(child_spec_paths)}

    ## User Stories
    #{format_user_stories(stories)}

    #{format_project_executive_summary(project)}

    ## Review Tasks

    1. **Read All Spec Files**: Read the context spec and all child component specs.

    2. **Validate Architecture**:
       - Proper separation of concerns between components
       - Appropriate use of component types (schema, repository, service, etc.)
       - Logical dependency relationships
       - No circular dependencies

    3. **Check Integration**:
       - Child components integrate cleanly with the context
       - Clear public APIs and delegation points
       - Data flow is well-defined

    4. **Verify Story Coverage**:
       - Each user story can be satisfied by the design
       - No gaps in acceptance criteria coverage

    5. **Fix Issues**: If you find problems, update the spec files directly.

    6. **Write Review**: Document your findings using the format below.

    ## Review Document Format
    #{document_spec}

    ## Output

    Write your review to: **#{review_file_path}**

    The review should be concise - focus on findings, not repetition of what was reviewed.
    """

    {:ok, prompt}
  end

  defp format_child_spec_paths([]) do
    "No child components to review."
  end

  defp format_child_spec_paths(paths) do
    Enum.map_join(paths, "\n", fn {name, type, path} -> "- #{name} (#{type}): #{path}" end)
  end

  defp format_user_stories([]) do
    "No user stories have been associated with this context."
  end

  defp format_user_stories(stories) do
    stories
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {story, index} ->
      acceptance_criteria = format_acceptance_criteria(story.acceptance_criteria)

      """
      ### Story #{index}: #{story.title}

      #{story.description}

      **Acceptance Criteria:**
      #{acceptance_criteria}
      """
      |> String.trim()
    end)
  end

  defp format_acceptance_criteria([]), do: "- None specified"

  defp format_acceptance_criteria(criteria) when is_list(criteria) do
    Enum.map_join(criteria, "\n", fn criterion -> "- #{criterion}" end)
  end

  defp format_project_executive_summary(%{executive_summary: nil}), do: ""

  defp format_project_executive_summary(%{executive_summary: summary})
       when is_binary(summary) and summary != "" do
    """
    ## Project Executive Summary

    #{summary}
    """
  end

  defp format_project_executive_summary(_project), do: ""

  # Private functions - Evaluation

  defp read_review_file(scope, review_file_path) do
    environment = scope.environment

    case Environments.read_file(environment, review_file_path) do
      {:ok, content} ->
        if String.trim(content) == "" do
          {:error, "Review file is empty"}
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:error, "Review file not found at #{review_file_path}"}

      {:error, error} ->
        {:error, "Failed to read file #{review_file_path}: #{inspect(error)}"}
    end
  end

  defp validate_document(review_content) do
    Documents.create_dynamic_document(review_content, "design_review")
  end

  defp build_revision_feedback(validation_errors) do
    """
    The design review document failed validation:

    Validation errors:
    #{validation_errors}

    Please revise the review document to address these validation errors while maintaining the overall findings and conclusions.
    """
  end
end
