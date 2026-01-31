defmodule CodeMySpec.Sessions.AgentTasks.ArchitectureDesign do
  @moduledoc """
  Architecture design session for Claude Code slash commands.

  Initiates a guided architecture design session that maps user stories
  to application surface components (controllers, liveviews, CLI modules).

  Two main functions:
  - `command/3` - Called by slash command to generate the design prompt
  - `evaluate/3` - Called by stop hook (currently auto-approves)
  """

  alias CodeMySpec.{Components, Stories, Architecture}

  @doc """
  Generate the command/prompt for Claude to start architecture design.

  Called by the slash command to build the prompt with:
  - Current architecture overview
  - Unsatisfied user stories
  - Component counts by type
  - References to architecture view files

  For greenfield projects (0 components), uses a specialized workflow
  with story analysis and proposal tools.

  Returns {:ok, prompt_text}
  """
  def command(scope, session, _opts \\ []) do
    %{project: project} = session
    working_dir = Map.get(session, :working_dir)

    stories = Stories.list_unsatisfied_stories(scope)
    component_count = Components.count_components(scope)

    # Generate fresh architecture views
    output_dir =
      if working_dir do
        Path.join(working_dir, "docs/architecture/")
      else
        "docs/architecture/"
      end

    Architecture.generate_views(scope, output_dir: output_dir)

    prompt =
      if component_count == 0 do
        build_greenfield_prompt(project, stories, output_dir)
      else
        build_design_prompt(project, stories, component_count, output_dir)
      end

    {:ok, prompt}
  end

  @doc """
  Evaluate the architecture design session output.

  Architecture design is a conversational session - no strict validation.
  Returns {:ok, :valid} to allow the session to complete.
  """
  def evaluate(_scope, _session, _opts \\ []) do
    {:ok, :valid}
  end

  # Private functions

  defp build_greenfield_prompt(project, stories, _output_dir) do
    stories_section = format_stories(stories)
    app_name = derive_app_name(project.name)

    """
    # Greenfield Architecture Design Session

    You are beginning an architecture design session for the **#{project.name}** project.
    This is a **greenfield project** with no existing components.

    ## Project Overview

    **Name:** #{project.name}
    **Description:** #{project.description || "No description provided"}

    ## User Stories

    #{stories_section}

    ## CRITICAL RULE: Where Stories Go

    **Stories map to SURFACE COMPONENTS only. Never to contexts.**

    - CORRECT: `surface_components: [{name: "AppWeb.DashboardLive", story_ids: [1,2,3]}]`
    - WRONG: `contexts: [{name: "App.Verification", story_ids: [1,2,3]}]` ← VALIDATION WILL REJECT THIS

    Why? Stories describe user interactions. Users interact through LiveViews and Controllers
    (the surface layer), not through contexts. Contexts provide domain logic that surfaces call.

    ## Architecture Pattern

    ```
    User Story → Surface Component → Context → Schema
                 (where story_ids go)  (NO story_ids)
    ```

    ## Your Task

    ### Step 1: Analyze Stories

    ```
    analyze_stories(app_name: "#{app_name}")
    ```

    ### Step 2: Design Surface Components (WITH story_ids)

    For each story, ask: "What screen/endpoint handles this user interaction?"

    Create surface components and map stories to them:
    - `liveview` - Real-time UI, dashboards, forms
    - `controller` - REST APIs, webhooks

    Naming: `#{app_name}Web.{Feature}Live` or `#{app_name}Web.{Feature}Controller`

    ### Step 3: Design Contexts (NO story_ids)

    For each surface component, ask: "What domain logic does this UI need?"

    Create contexts with child schemas/modules. **Do not add story_ids to contexts.**

    **ALL names must be fully qualified module names:**
    - Context: `#{app_name}.Verification`
    - Child: `#{app_name}.Verification.Transaction` (starts with parent context name)
    - Nested: `#{app_name}.Verification.Photos.Metadata` (for deeper hierarchies)

    ### Step 4: Define Dependencies

    Surface → Context (required):
    - `#{app_name}Web.DashboardLive` → `#{app_name}.Verification`

    Context → Context (optional):
    - `#{app_name}.Orders` → `#{app_name}.Catalog`

    ### Step 5: Create Proposal

    ```json
    {
      "app_name": "#{app_name}",
      "surface_components": [
        {
          "name": "#{app_name}Web.DashboardLive",
          "type": "liveview",
          "description": "Real-time dashboard for monitoring verifications",
          "story_ids": [1, 2, 3]
        },
        {
          "name": "#{app_name}Web.WebhookController",
          "type": "controller",
          "description": "API endpoint for external transaction submissions",
          "story_ids": [4, 5]
        }
      ],
      "contexts": [
        {
          "name": "#{app_name}.Verification",
          "description": "Verification workflow logic and data access",
          "children": [
            {"name": "#{app_name}.Verification.Transaction", "type": "schema", "description": "A transaction record"},
            {"name": "#{app_name}.Verification.Photo", "type": "schema", "description": "Verification photo"},
            {"name": "#{app_name}.Verification.Workflow", "type": "module", "description": "State machine logic"}
          ]
        }
      ],
      "dependencies": [
        {"from": "#{app_name}Web.DashboardLive", "to": "#{app_name}.Verification"},
        {"from": "#{app_name}Web.WebhookController", "to": "#{app_name}.Verification"}
      ]
    }
    ```

    **Notice:**
    - `story_ids` appear ONLY on surface_components
    - ALL names are fully qualified module names
    - Contexts start with `#{app_name}.`
    - Surface components start with `#{app_name}Web.`
    - Children start with their parent context name (e.g., `#{app_name}.Verification.Transaction`)

    ### Step 6: Validate and Execute

    1. `validate_proposal` - Rejects story_ids on contexts
    2. `execute_proposal` with `dry_run: true` - Preview
    3. `execute_proposal` - Create specs

    ## Available Tools

    - `analyze_stories` - Analyze stories to identify patterns and groupings
    - `propose_architecture` - Create an architecture proposal
    - `validate_proposal` - Validate proposal for issues
    - `execute_proposal` - Create specs from proposal (supports dry_run)
    - `create_context_with_children` - Create a single context with children
    - `create_spec` - Create a single component spec

    ## Begin

    Start with `analyze_stories`, then design surface components (with story_ids),
    then contexts (without story_ids), then dependencies.
    """
  end

  defp derive_app_name(project_name) do
    project_name
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> Macro.camelize()
  end

  defp build_design_prompt(project, stories, component_count, output_dir) do
    stories_section = format_stories(stories)

    """
    # Architecture Design Session

    You are beginning an architecture design session for the #{project.name} project.

    ## Project Overview

    **Name:** #{project.name}
    **Description:** #{project.description || "No description provided"}

    ## Current Architecture

    The project has #{component_count} components. Review the architecture views for details:

    - **Overview:** #{Path.join(output_dir, "overview.md")}
    - **Dependency Graph:** #{Path.join(output_dir, "dependency_graph.mmd")}
    - **Namespace Hierarchy:** #{Path.join(output_dir, "namespace_hierarchy.md")}

    ## Unsatisfied User Stories

    #{stories_section}

    ## Your Task

    Design how these stories should be implemented in the architecture:

    1. **Read the architecture views** to understand the current system structure
    2. **Map stories to surface components** - Which controllers, LiveViews, or CLI modules handle each story?
    3. **Identify new components needed** - What bounded contexts, schemas, or modules are missing?
    4. **Consider dependencies** - How do new components relate to existing ones?

    Use the architecture tools to:
    - `list_specs` or `list_spec_names` - Browse existing components
    - `get_spec` - Read component specifications
    - `get_component_view` - See a component's dependency tree
    - `create_spec` - Create new component specifications
    - `validate_dependency_graph` - Check for circular dependencies

    Begin by reading the architecture overview, then propose how to satisfy the unsatisfied stories.
    """
  end

  defp format_stories([]) do
    "All user stories are currently satisfied by the architecture."
  end

  defp format_stories(stories) do
    stories
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {story, index} ->
      acceptance_criteria =
        case story.acceptance_criteria do
          [] -> "  None specified"
          nil -> "  None specified"
          criteria -> Enum.map_join(criteria, "\n", &"  - #{&1}")
        end

      """
      ### #{index}. #{story.title}

      #{story.description || "No description"}

      **Acceptance Criteria:**
      #{acceptance_criteria}
      """
      |> String.trim()
    end)
  end
end
