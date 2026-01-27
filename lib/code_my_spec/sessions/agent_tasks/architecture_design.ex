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

    """
    # Greenfield Architecture Design Session

    You are beginning an architecture design session for the **#{project.name}** project.
    This is a **greenfield project** with no existing components.

    ## Project Overview

    **Name:** #{project.name}
    **Description:** #{project.description || "No description provided"}

    ## User Stories

    #{stories_section}

    ## Your Task: Design the Architecture from Scratch

    Follow this workflow to design and create the architecture:

    ### Step 1: Analyze the Stories

    Run `analyze_stories` to understand the domain:
    - This will group stories by theme/domain
    - Extract potential entities from story text
    - Detect surface component patterns (real-time, API, file upload, etc.)
    - Suggest bounded contexts

    ```
    analyze_stories(app_name: "#{derive_app_name(project.name)}")
    ```

    ### Step 2: Design the Architecture Proposal

    Based on the analysis, use `propose_architecture` to sketch your design:
    - Define bounded contexts with their child components
    - Define surface components (LiveViews, Controllers)
    - Map stories to the components that satisfy them
    - Define dependencies between contexts

    Example structure:
    ```json
    {
      "app_name": "#{derive_app_name(project.name)}",
      "contexts": [
        {
          "name": "#{derive_app_name(project.name)}.Verification",
          "description": "Handles verification workflows",
          "children": [
            {"name": "Transaction", "type": "schema", "story_ids": [1, 2]},
            {"name": "Photo", "type": "schema", "story_ids": [4, 5]}
          ],
          "story_ids": [1, 2, 3, 4, 5]
        }
      ],
      "surface_components": [
        {
          "name": "#{derive_app_name(project.name)}Web.VerificationLive",
          "type": "liveview",
          "description": "Real-time verification dashboard",
          "story_ids": [13, 14]
        }
      ],
      "dependencies": [
        {"from": "#{derive_app_name(project.name)}Web.VerificationLive", "to": "#{derive_app_name(project.name)}.Verification"}
      ]
    }
    ```

    ### Step 3: Validate the Proposal

    Use `validate_proposal` to check for issues:
    - All stories should be mapped to components
    - No circular dependencies
    - Valid module naming conventions
    - No empty contexts

    Fix any validation errors before proceeding.

    ### Step 4: Execute the Proposal

    Once validated, use `execute_proposal` to create all specs:
    - Use `dry_run: true` first to preview what will be created
    - Then run without dry_run to create the specs

    ### Alternative: Batch Context Creation

    For creating contexts one at a time with more control, use `create_context_with_children`:
    ```json
    {
      "module_name": "#{derive_app_name(project.name)}.Verification",
      "description": "Handles verification workflows",
      "story_ids": [1, 2, 3],
      "children": [
        {"name": "Transaction", "type": "schema", "description": "A fuel transaction", "story_ids": [1, 2]},
        {"name": "Photo", "type": "schema", "description": "Verification photo", "story_ids": [4, 5]}
      ]
    }
    ```

    ## Available Tools

    ### Story Analysis
    - `analyze_stories` - Analyze stories to understand domain and suggest contexts

    ### Proposal Workflow
    - `propose_architecture` - Create an architecture proposal
    - `validate_proposal` - Validate proposal for issues
    - `execute_proposal` - Create all specs from proposal (supports dry_run)

    ### Batch Creation
    - `create_context_with_children` - Create a context with all child components

    ### Individual Creation
    - `create_spec` - Create a single component spec (now supports story_ids)

    ## Begin

    Start by running `analyze_stories` to understand the domain, then design your architecture proposal.
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
