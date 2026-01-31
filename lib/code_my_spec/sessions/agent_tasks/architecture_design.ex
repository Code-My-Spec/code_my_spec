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
  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments

  @proposal_path "docs/architecture/proposal.md"

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

  Reads the proposal file and validates it (does NOT execute).
  Returns:
  - {:ok, :valid} if proposal is valid (model should then call execute_proposal)
  - {:ok, :invalid, feedback} if proposal has errors (blocks Claude from stopping)
  """
  def evaluate(scope, session, _opts \\ []) do
    working_dir = Map.get(session, :working_dir, File.cwd!())
    project = Map.get(session, :project)
    app_name = get_app_name(project)

    with {:ok, env} <- Environments.create(:cli, working_dir: working_dir),
         {:ok, content} <- read_proposal(env),
         {:ok, proposal} <- Proposal.from_markdown(content, app_name: app_name),
         {:ok, story_ids} <- get_story_ids(scope),
         {:ok, _validated} <- Proposal.validate(proposal, story_ids: story_ids) do
      Environments.destroy(env)

      # Proposal is valid - tell model to execute explicitly
      IO.puts("\n✓ Proposal validated successfully!")
      IO.puts("  Call `execute_proposal` to create spec files.")
      {:ok, :valid}
    else
      {:error, :proposal_not_found} ->
        {:ok, :invalid, proposal_not_found_feedback()}

      {:error, parse_error} when is_binary(parse_error) ->
        {:ok, :invalid, "Proposal parse error:\n\n#{parse_error}"}

      {:error, validation_errors} when is_list(validation_errors) ->
        {:ok, :invalid, format_validation_errors(validation_errors)}

      {:error, reason} ->
        {:ok, :invalid, "Error: #{inspect(reason)}"}
    end
  end

  defp read_proposal(env) do
    case Environments.read_file(env, @proposal_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :proposal_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_story_ids(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> {:ok, Enum.map(stories, & &1.id)}
      {:error, _} -> {:ok, []}
    end
  end

  defp get_app_name(%{module_name: module_name}) when is_binary(module_name), do: module_name
  defp get_app_name(%{name: name}) when is_binary(name), do: Macro.camelize(name)
  defp get_app_name(_), do: raise("Project must have module_name or name for architecture design")

  defp proposal_not_found_feedback do
    """
    Proposal file not found at: #{@proposal_path}

    Please write your architecture proposal to this file before finishing.
    The proposal must follow the architecture_proposal document format.
    """
  end

  defp format_validation_errors(errors) do
    error_list =
      errors
      |> Enum.map(fn err ->
        details = if err.details, do: "\n  Details: #{inspect(err.details)}", else: ""
        "- #{err.message}#{details}"
      end)
      |> Enum.join("\n")

    """
    Proposal validation failed:

    #{error_list}

    Please fix these issues in #{@proposal_path} and try again.
    """
  end

  # Private functions

  defp build_greenfield_prompt(project, stories, _output_dir) do
    stories_section = format_stories(stories)
    app_name = derive_app_name(project.name)
    document_spec = DocumentSpecProjector.project_spec("architecture_proposal")
    proposal_path = "docs/architecture/proposal.md"

    """
    # Greenfield Architecture Design Session

    You are beginning an architecture design session for the **#{project.name}** project.
    This is a **greenfield project** with no existing components.

    ## Project Overview

    **Name:** #{project.name}
    **App Module:** #{app_name}
    **Description:** #{project.description || "No description provided"}

    ## User Stories

    #{stories_section}

    ## CRITICAL RULE: Dual Story Mapping

    **Each story MUST be mapped to BOTH a surface component AND a context/child.**

    - CORRECT: Story 1 appears on BOTH `#{app_name}Web.DashboardLive` AND `#{app_name}.Verification.Transaction`
    - WRONG: Story 1 only on surface OR only on context ← VALIDATION WILL REJECT THIS

    ## Your Task

    ### Step 1: Analyze Stories

    Use `analyze_stories` to identify patterns and groupings.

    ### Step 2: Design the Architecture

    For each story, determine:
    - **Surface Component**: What screen/endpoint handles the user interaction? (LiveView, Controller)
    - **Context/Child**: What domain logic implements this? (Schema, Module)

    ### Step 3: Write the Proposal

    Write your proposal directly to: `#{proposal_path}`

    The proposal must follow this exact format:

    #{document_spec}

    **Naming Rules:**
    - Contexts: `#{app_name}.{ContextName}` (e.g., `#{app_name}.Accounts`)
    - Children: `#{app_name}.{Context}.{Child}` (e.g., `#{app_name}.Accounts.User`)
    - Surface: `#{app_name}Web.{Name}Live` or `#{app_name}Web.{Name}Controller`

    ### Step 4: Validate and Execute

    1. Stop when your proposal is complete - the system will validate it
    2. If validation passes, call `execute_proposal` to create the spec files
    3. Use `execute_proposal` with `dry_run: true` first to preview what will be created

    ## Begin

    1. Optionally use `analyze_stories` to identify patterns
    2. Write your proposal to `#{proposal_path}`
    3. Stop - the system will validate your proposal
    4. If valid, call `execute_proposal` to create spec files
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
    - `validate_dependency_graph` - Check for circular dependencies

    Begin by reading the architecture overview, then write a proposal to `docs/architecture/proposal.md`.
    """
  end

  defp format_stories([]) do
    "All user stories are currently satisfied by the architecture."
  end

  defp format_stories(stories) do
    stories
    |> Enum.map_join("\n\n", fn story ->
      acceptance_criteria =
        case story.acceptance_criteria do
          [] -> "  None specified"
          nil -> "  None specified"
          criteria -> Enum.map_join(criteria, "\n", &"  - #{&1}")
        end

      """
      ### Story #{story.id}: #{story.title}

      #{story.description || "No description"}

      **Acceptance Criteria:**
      #{acceptance_criteria}

      **Use story_id: #{story.id}** when mapping this story to components.
      """
      |> String.trim()
    end)
  end
end
