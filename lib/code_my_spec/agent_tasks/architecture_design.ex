defmodule CodeMySpec.AgentTasks.ArchitectureDesign do
  @moduledoc """
  Architecture design session for Claude Code slash commands.

  Initiates a guided architecture design session that maps user stories
  to application surface components (controllers, liveviews, CLI modules).

  Two main functions:
  - `command/2` - Called by slash command to generate the design prompt
  - `evaluate/2` - Called by stop hook to validate and execute the proposal
  """

  alias CodeMySpec.{Architecture, Components, Paths, Stories}
  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @proposal_path Paths.proposal_path()

  @doc """
  Generate the command/prompt for Claude to start architecture design.

  Called by the slash command to build the prompt with:
  - Current architecture overview
  - Unsatisfied user stories
  - Component counts by type
  - References to architecture view files

  Returns {:ok, prompt_text}
  """
  def command(scope, _task) do
    project = scope.active_project
    working_dir = scope.environment && scope.environment.cwd

    stories = Stories.list_unsatisfied_stories(scope)
    component_count = Components.count_components(scope)

    # Generate fresh architecture views
    output_dir =
      if working_dir do
        Path.join(working_dir, Paths.architecture_dir())
      else
        Paths.architecture_dir()
      end

    Architecture.generate_views(scope, output_dir: output_dir)

    prompt = build_prompt(project, stories, component_count, output_dir)

    {:ok, prompt}
  end

  @doc """
  Evaluate the architecture design session output.

  Reads the proposal file, validates it, and executes it (creating specs and linking stories).
  Returns:
  - {:ok, :valid} if proposal is valid and execution succeeds
  - {:ok, :invalid, feedback} if proposal has errors or execution fails
  """
  def evaluate(scope, _task) do
    working_dir = (scope.environment && scope.environment.cwd) || File.cwd!()
    project = scope.active_project
    app_name = get_app_name(project)

    env = scope.environment || Environment.new(:cli, working_dir)

    with {:ok, content} <- read_proposal(env),
         {:ok, proposal} <- Proposal.from_markdown(content, app_name: app_name),
         {:ok, story_ids} <- get_story_ids(scope),
         {:ok, _validated} <- Proposal.validate(proposal, story_ids: story_ids),
         {:ok, result} <- Proposal.execute(proposal, scope, working_dir: working_dir) do
      IO.puts("\n✓ Proposal validated and executed successfully!")

      IO.puts(
        "  Created #{result.created_contexts} contexts, #{result.created_components} components"
      )

      IO.puts("  Linked #{result.linked_stories} stories")
      IO.puts("  Spec files written to .code_my_spec/spec/")
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
      |> Enum.map_join("\n", fn err ->
        details = if err.details, do: "\n  Details: #{inspect(err.details)}", else: ""
        "- #{err.message}#{details}"
      end)

    """
    Proposal validation failed:

    #{error_list}

    Please fix these issues in #{@proposal_path} and try again.
    """
  end

  # Private functions

  defp build_prompt(project, stories, component_count, output_dir) do
    stories_section = format_stories(stories)
    app_name = derive_app_name(project.name)
    document_spec = DocumentSpecProjector.project_spec("architecture_proposal")

    architecture_section =
      if component_count > 0 do
        """
        ## Current Architecture

        The project has #{component_count} existing components. Review the architecture views for details:

        - **Overview:** #{Path.join(output_dir, "overview.md")}
        - **Dependency Graph:** #{Path.join(output_dir, "dependency_graph.mmd")}
        - **Namespace Hierarchy:** #{Path.join(output_dir, "namespace_hierarchy.md")}

        Browse existing specs directly:
        - Run `tree .code_my_spec/spec/` or `ls -R .code_my_spec/spec/` to see all component specs
        - Read any spec file directly to review its contents
        - Use `validate_dependency_graph` tool to check for circular dependencies
        """
      else
        ""
      end

    """
    # Architecture Design Session

    You are beginning an architecture design session for the **#{project.name}** project.

    ## Project Overview

    **Name:** #{project.name}
    **App Module:** #{app_name}
    **Description:** #{project.description || "No description provided"}

    #{architecture_section}## User Stories

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

    Consider how new components relate to existing ones (if any).

    ### Step 3: Write the Proposal

    Write your proposal directly to: `#{@proposal_path}`

    The proposal must follow this exact format:

    #{document_spec}

    **Naming Rules:**
    - Contexts: `#{app_name}.{ContextName}` (e.g., `#{app_name}.Accounts`)
    - Children: `#{app_name}.{Context}.{Child}` (e.g., `#{app_name}.Accounts.User`)
    - Surface: `#{app_name}Web.{Name}Live` or `#{app_name}Web.{Name}Controller`

    ### Step 4: Submit for Validation

    Stop when your proposal is complete. The system will automatically validate and execute it,
    creating all spec files and linking stories. If validation fails, you'll receive feedback to fix.

    ## Begin

    1. Optionally use `analyze_stories` to identify patterns
    2. Write your proposal to `#{@proposal_path}`
    3. Stop - the system will validate and execute your proposal
    """
  end

  defp derive_app_name(project_name) do
    project_name
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> Macro.camelize()
  end

  defp format_stories([]) do
    "All user stories are currently satisfied by the architecture."
  end

  defp format_stories(stories) do
    stories
    |> Enum.map_join("\n\n", fn story ->
      acceptance_criteria =
        case criteria_descriptions(story) do
          [] -> "  None specified"
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

  defp criteria_descriptions(story) do
    case story.criteria do
      criteria when is_list(criteria) and criteria != [] ->
        Enum.map(criteria, & &1.description)

      _ ->
        story.acceptance_criteria || []
    end
  end
end
