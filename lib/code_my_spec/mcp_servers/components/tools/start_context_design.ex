defmodule CodeMySpec.McpServers.Components.Tools.StartContextDesign do
  @moduledoc "Initiates guided context design session"

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        build_design_prompt(scope, frame)

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp build_design_prompt(scope, frame) do
    stories = Stories.list_unsatisfied_stories(scope)
    components = Components.list_components_with_dependencies(scope)

    prompt = """
    You are an expert Elixir architect specializing in Phoenix contexts.
    Your job is to design a clean context architecture that satisfies the user stories.
    We will only focus on unsatisfied user stories for this conversation, so if there are no unsatisfied user stories, there's nothing to do.

    **Unsatisfied User Stories:**
    #{format_stories_context(stories)}

    **Existing Components:**
    #{format_components_context(components)}

    **Your Role:**
    - Map user stories to Phoenix contexts based on entity ownership
    - Use business capability grouping within entity boundaries
    - Ensure flat context structure (no nested contexts)
    - Distinguish between domain contexts (own entities) and coordination contexts (orchestrate workflows)
    - Create components and dependencies to represent the complete system

    **Context Design Principles:**
    - Each user story should map to exactly one context
    - Domain contexts should own at least one entity type
    - Coordination contexts orchestrate workflows across domains
    - Dependencies should be explicit and justified
    - Avoid circular dependencies
    - Keep context responsibilities clear and focused

    **Instructions:**
    Start by reviewing the existing stories and components above, then guide me through creating or refining the context architecture.
    Ask questions about domain boundaries, entity ownership, and workflow orchestration needs.
    """

    {:reply, ComponentsMapper.prompt_response(prompt), frame}
  end

  defp format_stories_context([]),
    do: "The requirements for all user stories have been satisfied."

  defp format_stories_context(stories) do
    Enum.map_join(stories, "\n\n", &format_story_summary/1)
  end

  defp format_story_summary(story) do
    criteria =
      case criteria_descriptions(story) do
        [] ->
          "No acceptance criteria defined"

        criteria ->
          Enum.map_join(criteria, "\n", &"- #{&1}")
      end

    """
    **#{story.title}**
    #{story.description}

    Acceptance Criteria:
    #{criteria}
    """
  end

  defp format_components_context([]), do: "No components currently exist for this project."

  defp format_components_context(components) do
    Enum.map_join(components, "\n\n", &format_component_summary/1)
  end

  defp format_component_summary(component) do
    dependencies = format_dependencies(component.outgoing_dependencies)

    """
    **#{component.name}** (#{component.type})
    Module: #{component.module_name}
    #{if component.description, do: "Description: #{component.description}", else: "No description"}

    Dependencies:
    #{dependencies}
    """
  end

  defp format_dependencies([]), do: "None"

  defp format_dependencies(dependencies) do
    Enum.map_join(dependencies, "\n", &"- #{&1.target_component.name}")
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
