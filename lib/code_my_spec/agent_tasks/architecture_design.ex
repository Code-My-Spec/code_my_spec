defmodule CodeMySpec.AgentTasks.ArchitectureDesign do
  @moduledoc """
  Map user stories to application components via proposal + MCP-tool mutations.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/architecture_design.spec.md`.
  """

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.{Components, Paths, Stories}
  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Requirements.ArchitectureChecker

  @proposal_path Paths.proposal_path()
  @patch_mode_marker Path.join(Paths.architecture_dir(), ".proposal_pre_existed_at_session_start")

  def dispatch(_node) do
    "Map user stories to application components (surfaces, contexts, children) " <>
      "via the architecture MCP tools (analyze_stories, create_component, " <>
      "validate_dependency_graph, set_story_component, execute_proposal). " <>
      "Runs in initial or revision mode depending on whether proposal.md " <>
      "exists. Use when stories have linked criteria but no components, or " <>
      "when the proposal exists but unsatisfied stories / orphan contexts " <>
      "remain."
  end

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
    orphans = ArchitectureChecker.orphans(scope)
    component_count = Components.count_components(scope)

    # The caller's environment or none. Inventing one at this server's
    # directory made `proposal_exists?` answer about *this* repository.
    env = scope.environment || cli_env(working_dir)
    proposal_exists? = Environments.file_exists?(env, @proposal_path)
    record_session_start_state(env, proposal_exists?)

    # Generate fresh architecture views
    output_dir =
      if working_dir do
        Path.join(working_dir, Paths.architecture_dir())
      else
        Paths.architecture_dir()
      end

    prompt =
      build_prompt(project, stories, orphans, component_count, output_dir, proposal_exists?)

    {:ok, prompt}
  end

  defp record_session_start_state(env, true),
    do: Environments.write_file(env, @patch_mode_marker, "1")

  defp record_session_start_state(env, false),
    do: Environments.delete_file(env, @patch_mode_marker)

  defp patch_mode?(env), do: Environments.file_exists?(env, @patch_mode_marker)

  @doc """
  Evaluate the architecture design session output.

  Reads the proposal file, validates it, and executes it (creating specs and linking stories).
  Returns:
  - {:ok, :valid} if proposal is valid and execution succeeds
  - {:ok, :invalid, feedback} if proposal has errors or execution fails
  """
  def evaluate(scope, _task) do
    working_dir = scope.environment && scope.environment.cwd
    env = scope.environment

    # Don't clear the marker on evaluate — `command/2` owns the lifecycle.
    # A failing patch-mode evaluate (e.g. unlinked story) used to clear the
    # marker and silently promote the next evaluate to full proposal
    # validation, forcing the architect to hand-edit proposal.md after
    # any DB-side fix. The marker survives until the next `start_task`,
    # which re-records based on proposal existence.
    if patch_mode?(env) do
      evaluate_patch_mode(scope)
    else
      evaluate_initial_mode(scope, env, working_dir)
    end
  end

  # Patch mode: proposal pre-existed at session start. The architect used the
  # incremental tools (`create_component`, `set_story_component`) — or chose
  # not to do anything — without rewriting the proposal end-to-end. Skip
  # auto-execution of the (now potentially stale) proposal and verify the
  # gate directly: every project story has a linked component.
  defp evaluate_patch_mode(scope) do
    case unlinked_story_ids(scope) do
      [] -> {:ok, :valid}
      ids -> {:ok, :invalid, unlinked_stories_feedback(ids)}
    end
  end

  @doc """
  Forces a full read-validate-execute cycle on the proposal regardless of
  patch mode. Called by the `execute_proposal` MCP tool when the architect
  explicitly chooses the rewrite path in patch mode.
  """
  @spec execute_proposal(map()) ::
          {:ok, :valid} | {:ok, :valid, String.t()} | {:ok, :invalid, String.t()}
  def execute_proposal(scope) do
    working_dir = scope.environment && scope.environment.cwd
    env = scope.environment
    evaluate_initial_mode(scope, env, working_dir)
  end

  defp evaluate_initial_mode(scope, env, working_dir) do
    project = scope.active_project
    app_name = get_app_name(project)

    with {:ok, content} <- read_proposal(env),
         {:ok, proposal} <- Proposal.from_markdown(content, app_name: app_name),
         {:ok, story_ids} <- get_story_ids(scope),
         db_components = list_db_component_names(scope),
         {:ok, _validated} <-
           Proposal.validate(proposal, story_ids: story_ids, db_components: db_components),
         {:ok, result} <- Proposal.execute(proposal, scope, env: env, working_dir: working_dir) do
      case Map.get(result, :warnings, []) do
        [] -> {:ok, :valid}
        warnings -> {:ok, :valid, format_warnings(warnings)}
      end
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

  defp unlinked_story_ids(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        stories
        |> Enum.reject(&(&1.component_id != nil))
        |> Enum.map(& &1.id)

      {:error, _} ->
        []
    end
  end

  defp unlinked_stories_feedback(ids) do
    """
    Some stories are not linked to a component:

    #{Enum.map_join(ids, "\n", &"- Story #{&1}")}

    Use `set_story_component` to link each story, or rewrite #{@proposal_path} and call `execute_proposal` to apply a fresh design.
    """
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

  defp list_db_component_names(scope) do
    scope
    |> Components.list_components()
    |> Enum.map(& &1.module_name)
  end

  defp format_warnings(warnings) do
    bullets = Enum.map_join(warnings, "\n", &"- #{&1}")
    "## Warnings\n\n#{bullets}"
  end

  # `module_name` is the only authority. It is what the sprite names the
  # generated app after, so it is the one value guaranteed to match the modules
  # and boundaries actually on disk.
  #
  # This module used to derive a second app name alongside this one, by
  # stripping every non-alphanumeric out of the project's *display* name and
  # camelizing the result. For a project called "e2e-todo" that produced
  # `E2etodo` while the repo defined `E2eTodo` — one letter apart, and a module
  # tree no boundary claims. Two derivations in one file, disagreeing, and the
  # prompt handed out the wrong one: an agent registered fourteen components
  # under `E2etodo.` before noticing and refused to paper over it in code.
  # Only when a directory was actually supplied. `nil` means this server has
  # no working copy for the project, which every caller below handles.
  defp cli_env(nil), do: nil
  defp cli_env(working_dir), do: Environment.new(:cli, working_dir)

  defp get_app_name(%{module_name: module_name}) when is_binary(module_name), do: module_name

  # Last resort only. Underscore first so `-` and ` ` are word boundaries —
  # `Macro.camelize/1` alone leaves "e2e-todo" as "E2e-todo", which is not a
  # module name at all.
  defp get_app_name(%{name: name}) when is_binary(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> Macro.underscore()
    |> Macro.camelize()
  end

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

  defp build_prompt(project, stories, orphans, component_count, output_dir, proposal_exists?) do
    stories_section = format_stories(stories, orphans)
    orphans_section = format_orphans_section(orphans)
    app_name = get_app_name(project)

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

    task_section =
      if proposal_exists? do
        revision_task_section(app_name)
      else
        initial_task_section(app_name)
      end

    """
    # Architecture Design — #{project.name}

    Map user stories to application components (surfaces, contexts,
    children) for **#{project.name}** (`#{app_name}`).

    Mutate the architecture via the architecture MCP tools wherever
    possible: `analyze_stories`, `create_component`, `update_component`,
    `validate_dependency_graph`, `set_story_component`, `execute_proposal`.
    Direct file edits are reserved for the spec `## Dependencies` section,
    which ComponentSync re-derives.

    ## Project

    **Name:** #{project.name}
    **App Module:** #{app_name}
    **Description:** #{project.description || "No description provided"}

    #{architecture_section}#{orphans_section}## User Stories

    #{stories_section}

    #{task_section}

    ## Read the playbook

    Read `architecture_design/workflow.md` via the `read_knowledge` MCP
    tool — full procedure for both modes, complete MCP tool reference,
    dependency-edge conventions, orphan resolution options, and
    anti-patterns to avoid.
    """
  end

  defp initial_task_section(app_name) do
    document_spec = DocumentSpecProjector.project_spec("architecture_proposal")

    """
    ## Mode — initial

    No proposal exists yet. Design the architecture end-to-end, write
    `#{@proposal_path}`, and stop. The evaluator validates the proposal
    against the `architecture_proposal` document spec AND executes it as one
    transaction — creating spec files under `.code_my_spec/spec/` and
    linking stories to components.

    Procedure:
    1. Call `analyze_stories` for groupings and suggested context names.
    2. Design surface / context / children per story (read the playbook for
       conventions).
    3. Write the proposal to `#{@proposal_path}`.
    4. Stop. The evaluator runs validate + execute atomically.

    ## Document format

    The proposal must match this spec exactly (the evaluator parses it
    against the `architecture_proposal` document type):

    #{document_spec}

    ## Naming conventions

    - Contexts: `#{app_name}.{ContextName}` (e.g., `#{app_name}.Accounts`).
    - Children: `#{app_name}.{Context}.{Child}` (e.g., `#{app_name}.Accounts.User`).
    - Surface: `#{app_name}Web.{Name}Live` or `#{app_name}Web.{Name}Controller`.
    """
  end

  defp revision_task_section(app_name) do
    """
    ## Mode — revision

    `#{@proposal_path}` already exists. Apply targeted edits via the
    architecture MCP tools to satisfy unsatisfied stories and resolve the
    architectural issues listed above. **Do not rewrite the proposal
    end-to-end** unless the changes are too sweeping for incremental tools.

    ### Primary tool surface (use these first)

    - **`set_story_component`** — link an unsatisfied story to an existing
      component. The simplest action when the architecture already has the
      right component.
    - **`create_component`** — add a new context / child / surface when no
      existing component fits. Scaffolds the spec file automatically.
    - **`update_component`** — edit existing component metadata; the spec
      file is re-projected.
    - **`validate_dependency_graph`** — run after every structural change.

    ### Dependencies are spec-derived, not a tool call

    To add an edge from a story-linked context to an orphan context, edit
    the story-linked context's spec file under `.code_my_spec/spec/` and
    append the orphan's module name as a bullet under `## Dependencies`.
    ComponentSync re-derives the graph on save.

    ### Naming conventions for new components

    - Contexts: `#{app_name}.{ContextName}` (e.g., `#{app_name}.Accounts`).
    - Children: `#{app_name}.{Context}.{Child}` (e.g., `#{app_name}.Accounts.User`).
    - Surface: `#{app_name}Web.{Name}Live` or `#{app_name}Web.{Name}Controller`.

    ### Fallback — full rewrite

    Only if the design needs a fresh pass: rewrite `#{@proposal_path}` to
    the `architecture_proposal` format and call `execute_proposal` to apply
    it. **The evaluator does NOT auto-execute in revision mode** — it only
    verifies every story is linked.

    ### Stop

    Stop when your edits are complete. The evaluator checks that every
    story has a linked component AND no orphan contexts remain.
    """
  end

  defp format_stories([], []) do
    "All user stories are currently satisfied by the architecture."
  end

  defp format_stories([], _orphans) do
    "Every user story is linked to a component, but the architecture is not done — see **Architectural Issues** above."
  end

  defp format_stories(stories, _orphans) do
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

  defp format_orphans_section([]), do: ""

  defp format_orphans_section(orphans) do
    bullets =
      Enum.map_join(orphans, "\n", fn c ->
        "- `#{c.module_name}` (type: `#{c.type || "module"}`)"
      end)

    """
    ## Architectural Issues

    The project DB has #{length(orphans)} orphan context(s) — contexts that are not linked to a story, not transitively depended on by a story-linked context, and not classified as infrastructure. The architecture is not done until each one is resolved:

    #{bullets}

    For each orphan context, choose one resolution:
    - Link a story directly to the context using `set_story_component`
    - Add a dependency edge from a story-linked context: edit that context's spec under `.code_my_spec/spec/` and add the orphan module as a bullet under `## Dependencies`. ComponentSync re-derives the graph on save.
    - Classify the context as framework boilerplate by editing its spec's `## Type` section to `infrastructure`. ComponentSync re-types the component on the next sync, the orphan rule skips infrastructure-typed components.
    - Delete the context's spec, implementation, and test files; ComponentSync will remove the component on the next sync

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
