defmodule CodeMySpec.AgentTasks.ContextDesignReview do
  @moduledoc """
  Context design review agent task for Claude Code slash commands.

  Two main functions:
  - `command/3` - Called by slash command to generate the review prompt for Claude
  - `evaluate/3` - Called by stop hook to validate the review document
  """

  require Logger

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementsFormatter
  alias CodeMySpec.Stories
  alias CodeMySpec.Utils

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
      {:ok,
       TaskMarker.build("ContextDesignReview", context_component.module_name) <> "\n\n" <> prompt}
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
    %{component: component} = session
    component = ComponentRepository.get_component(scope, component.id)

    review_reqs = Requirements.check_artifact_requirements(scope, component, :review)
    satisfied_count = Enum.count(review_reqs, & &1.satisfied)
    total = length(review_reqs)
    unsatisfied = Enum.filter(review_reqs, &(not &1.satisfied))

    Logger.info(
      "[ContextDesignReview] evaluate #{component.module_name}: #{satisfied_count}/#{total} review requirements pass"
    )

    if Enum.empty?(unsatisfied) do
      {:ok, :valid}
    else
      feedback =
        RequirementsFormatter.format_unsatisfied(unsatisfied,
          context: "Design review requirements not met:"
        )

      {:ok, :invalid, feedback}
    end
  end

  def orchestrate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate(__MODULE__, scope, session, opts)
  end

  def orchestrate_evaluate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate_evaluate(__MODULE__, scope, session, opts)
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
    # Context spec path: ".code_my_spec/spec/code_my_spec/sessions.spec.md"
    # Review file path: ".code_my_spec/spec/code_my_spec/sessions/design_review.md"
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

    1. **Read All Spec Files**: Read the context spec and every child component spec. Do not skip any.

    2. **Cross-check types against descriptions**: For every function, verify the @spec types make sense for what the component description says it does. A module described as doing numeric operations must use numeric types, not strings.

    3. **Verify every function belongs**: Each function in a component must align with that component's stated purpose. Flag any function that doesn't belong (e.g. multiply/2 in an addition-only module).

    4. **Check test assertions for contradictions**: Read each function's Test Assertions list. Flag any pair of assertions that contradict each other (e.g. same input producing different expected outputs).

    5. **Validate dependencies exist**: Every module listed in a Dependencies section must correspond to a real component in this architecture. Cross-reference against the context spec's Components section.

    6. **Check context delegates match child APIs**: The context spec's Delegates section should reference functions that actually exist in child component specs.

    7. **Verify story coverage**: Each user story's acceptance criteria should map to at least one function across the specs.

    8. **Fix Issues**: If you find ANY problems in steps 2-6, you MUST update the spec files directly before writing the review. Do not write a passing review with known issues.

    9. **Write Review**: Document your findings using the format below. The Issues section is REQUIRED if you fixed anything.

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
      acceptance_criteria = format_acceptance_criteria(story.criteria)

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
    Enum.map_join(criteria, "\n", fn criterion -> "- #{criterion.description}" end)
  end

  defp format_acceptance_criteria(other) do
    Logger.warning("[ContextDesignReview] Invalid acceptance_criteria: #{inspect(other)}")
    "- None specified"
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
end
