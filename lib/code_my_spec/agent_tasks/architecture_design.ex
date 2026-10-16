defmodule CodeMySpec.AgentTasks.ArchitectureDesign do
  @moduledoc """
  Map user stories to application components via proposal + MCP-tool mutations.

  Two modes. *Initial* (no components, no proposal): the agent writes
  `proposal.md` and the evaluator validates and executes it. *Revision*
  (components exist, or a proposal does): the agent edits through the
  architecture tools and the evaluator checks the task's story is linked. The
  mode chosen at `command/2` is recorded in a marker file that `evaluate/2`
  reads.

  See knowledge/tools, "Agent task prompts".
  """

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.{Components, Paths, Stories}
  alias CodeMySpec.Documents.DocumentSpecProjector
  require Logger

  alias CodeMySpec.Environments

  @proposal_path Paths.proposal_path()
  @patch_mode_marker Path.join(Paths.architecture_dir(), ".proposal_pre_existed_at_session_start")

  def dispatch(_node) do
    "Map user stories to application components (surfaces, contexts, children) " <>
      "via the architecture MCP tools (analyze_stories, create_component, " <>
      "validate_dependency_graph, set_story_component, execute_proposal). " <>
      "Runs in initial or revision mode depending on whether proposal.md " <>
      "exists. Use when the project has no architecture yet, or when a story " <>
      "needs a component."
  end

  @doc """
  Generate the command/prompt for Claude to start architecture design.

  The prompt carries the component count and the tools to read them, the
  unsatisfied stories with their criteria, and the mode's procedure.

  Returns {:ok, prompt_text}
  """
  def command(scope, task) do
    with {:ok, stories} <- task_stories(scope, task) do
      build_command(scope, stories)
    end
  end

  # Story numbers are resolved at the tool boundary; task.story_id is the
  # graph's database ID and must never be interpreted as a story number.
  defp task_stories(scope, %{story_id: id}) when not is_nil(id) do
    case Stories.get_story(scope, id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, [story]}
    end
  end

  defp task_stories(scope, _task), do: {:ok, Stories.list_unsatisfied_stories(scope)}

  defp build_command(scope, stories) do
    project = scope.active_project
    component_count = Components.count_components(scope)

    # The caller's environment or none, never one at this server's directory.
    env = CodeMySpec.AgentTasks.environment(scope)

    proposal_exists? = revision_mode?(env, component_count)

    record_session_start_state(env, proposal_exists?)

    prompt = build_prompt(project, stories, component_count, proposal_exists?)

    {:ok, prompt}
  end

  # Revision when there is an architecture to revise: component count decides
  # first, since `proposal.md` only records how the architecture was first
  # produced. Unlinked stories on an existing architecture want revision's
  # tools, not a redesign. With no components, the file decides.
  defp revision_mode?(_env, component_count) when component_count > 0, do: true

  defp revision_mode?(env, _component_count) do
    case proposal_status(env) do
      :present ->
        true

      :absent ->
        false

      # Could not look: assume present. Initial mode has the evaluator execute a
      # proposal end-to-end; revision's worst case is no edits.
      # See knowledge/tools, "Unobservable environments".
      :unobservable ->
        Logger.warning(
          "[ArchitectureDesign] could not read #{@proposal_path} in this environment. " <>
            "Assuming a proposal exists and staying in revision mode — an unreadable " <>
            "environment must not be read as an undesigned architecture."
        )

        true
    end
  end

  defp record_session_start_state(env, true),
    do: Environments.write_file(env, @patch_mode_marker, "1")

  defp record_session_start_state(env, false),
    do: Environments.delete_file(env, @patch_mode_marker)

  # Same asymmetry as `proposal_status/1`: an unreadable marker stays in patch
  # mode rather than promoting to a full proposal execution.
  defp patch_mode?(env) do
    case Environments.stat(env, @patch_mode_marker) do
      {:ok, _} ->
        true

      {:error, :enoent} ->
        false

      {:error, reason} ->
        Logger.warning(
          "[ArchitectureDesign] could not read the patch-mode marker (#{inspect(reason)}). " <>
            "Staying in patch mode — an unreadable environment must not promote this to a " <>
            "full proposal execution."
        )

        true
    end
  end

  @doc """
  Evaluate the architecture design session output.

  Reads the proposal file, validates it, and executes it (creating components and linking stories).
  Returns:
  - {:ok, :valid} if proposal is valid and execution succeeds
  - {:ok, :invalid, feedback} if proposal has errors or execution fails
  """
  # No environment, no answer: refuse before guessing a mode.
  def evaluate(scope, task) do
    env = CodeMySpec.AgentTasks.environment(scope)

    if is_nil(env) do
      {:error, :no_environment}
    else
      # The marker is never cleared here; `command/2` owns it. Clearing it on a
      # failing patch-mode evaluate would promote the next one to a full
      # proposal execution.
      if patch_mode?(env) do
        evaluate_patch_mode(scope, task)
      else
        evaluate_initial_mode(scope, env)
      end
    end
  end

  # Patch mode: a task for one story is done when that story has a component.
  # Other stories are their own tasks, and orphan components are not a gate.
  defp evaluate_patch_mode(scope, %{story_id: story_id}) when not is_nil(story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> {:error, :story_not_found}
      %{component_id: nil} = story -> {:ok, :invalid, unlinked_story_feedback(story)}
      _linked -> {:ok, :valid}
    end
  end

  defp evaluate_patch_mode(_scope, _task), do: {:ok, :valid}

  @doc """
  Forces a full read-validate-execute cycle on the proposal regardless of
  patch mode. Called by the `execute_proposal` MCP tool when the architect
  explicitly chooses the rewrite path in patch mode.
  """
  @spec execute_proposal(map()) ::
          {:ok, :valid} | {:ok, :valid, String.t()} | {:ok, :invalid, String.t()}
  def execute_proposal(scope) do
    case CodeMySpec.AgentTasks.environment(scope) do
      nil -> {:error, :no_environment}
      env -> evaluate_initial_mode(scope, env)
    end
  end

  defp evaluate_initial_mode(scope, env) do
    project = scope.active_project
    app_name = get_app_name(project)

    with {:ok, content} <- read_proposal(env),
         {:ok, proposal} <- Proposal.from_markdown(content, app_name: app_name),
         ids_by_number = Stories.list_story_ids_by_number(scope),
         labels = Map.new(ids_by_number, fn {number, id} -> {id, number} end),
         {:ok, linked} <- Proposal.link_story_numbers(proposal, ids_by_number),
         {:ok, story_numbers} <- get_story_numbers(scope),
         db_components = list_db_component_names(scope),
         {:ok, _validated} <-
           Proposal.validate(proposal, story_ids: story_numbers, db_components: db_components),
         {:ok, result} <-
           Proposal.execute(linked, scope, story_labels: labels) do
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

      # "Could not look" is not "unmet": passed through as an error so
      # `TaskEvaluator` can name it.
      {:error, reason} ->
        if Environments.unobservable?(reason) do
          {:error, reason}
        else
          {:ok, :invalid, "Error: #{inspect(reason)}"}
        end
    end
  end

  defp unlinked_story_feedback(story) do
    """
    Story #{story.number} is not linked to a component.

    Use `set_story_component` to link it, or `create_component` and then link that.
    """
  end

  defp read_proposal(env) do
    case Environments.read_file(env, @proposal_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :proposal_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_story_numbers(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> {:ok, Enum.map(stories, & &1.number)}
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

  # `stat`, not `file_exists?/2`, because only `stat` tells "not there" from
  # "could not look". A `nil` env is a known state (no working copy here), not
  # a failed read.
  defp proposal_status(nil), do: :absent

  defp proposal_status(env) do
    case Environments.stat(env, @proposal_path) do
      {:ok, _} -> :present
      {:error, :enoent} -> :absent
      {:error, _reason} -> :unobservable
    end
  end

  # `module_name` is the authority: it is what the generated app and its
  # boundaries are named after. A second derivation from the display name
  # disagrees with it (`E2etodo` vs `E2eTodo`).
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

  defp build_prompt(project, stories, component_count, proposal_exists?) do
    stories_section = format_stories(stories)
    app_name = get_app_name(project)

    architecture_section =
      if component_count > 0 do
        """
        ## Current Architecture

        The project has #{component_count} existing components. Read them:

        - `show_namespace_hierarchy` for the namespace tree (a prefix and depth open one subtree)
        - `get_component` for one component and its dependencies
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
    `validate_dependency_graph`, `set_story_component`, `add_dependency`,
    `remove_dependency`, `execute_proposal`.

    ## Project

    **Name:** #{project.name}
    **App Module:** #{app_name}
    **Description:** #{project.description || "No description provided"}

    #{architecture_section}## User Stories

    #{stories_section}

    #{task_section}

    ## Read the playbook

    Read `architecture_design/workflow.md` via the `read_knowledge` MCP
    tool — full procedure for both modes, complete MCP tool reference,
    dependency-edge conventions and anti-patterns to avoid.
    """
  end

  defp initial_task_section(app_name) do
    document_spec = DocumentSpecProjector.project_spec("architecture_proposal")

    """
    ## Mode — initial

    No proposal exists yet. Design the architecture end-to-end, write
    `#{@proposal_path}`, and stop. The evaluator validates the proposal
    against the `architecture_proposal` document spec AND executes it as one
    transaction — creating the components and their dependencies as records
    and linking stories to them.

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
    architecture MCP tools to give unlinked stories a component. **Do not
    rewrite the proposal
    end-to-end** unless the changes are too sweeping for incremental tools.

    Every unlinked story above gets a component this session: link it with
    `set_story_component` when one fits, otherwise `create_component` and
    link that. Map a story as written — a thin or odd story is not a reason
    to hold the task for a question.

    ### Primary tool surface (use these first)

    - **`set_story_component`** — link an unsatisfied story to an existing
      component. The simplest action when the architecture already has the
      right component.
    - **`create_component`** — add a new context / child / surface when no
      existing component fits; no proposal edit needed.
    - **`update_component`** — edit existing component metadata.
    - **`add_dependency`** / **`remove_dependency`** — the edges between
      components.
    - **`validate_dependency_graph`** — run after every structural change.

    ### Dependencies are records

    To make one component depend on another, call `add_dependency`. No file
    describes a component; editing a spec changes nothing.

    ### Naming conventions for new components

    - Contexts: `#{app_name}.{ContextName}` (e.g., `#{app_name}.Accounts`).
    - Children: `#{app_name}.{Context}.{Child}` (e.g., `#{app_name}.Accounts.User`).
    - Surface: `#{app_name}Web.{Name}Live` or `#{app_name}Web.{Name}Controller`.

    ### Fallback — full rewrite

    Only if the design needs a fresh pass: rewrite `#{@proposal_path}` to
    the `architecture_proposal` format and call `execute_proposal` to apply
    it. **The evaluator does NOT auto-execute in revision mode** — it only
    verifies the story is linked.

    ### Stop

    Stop when your edits are complete. The evaluator checks that the story
    this task is for has a linked component.
    """
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
      ### Story #{story.number}: #{story.title}

      #{story.description || "No description"}

      **Acceptance Criteria:**
      #{acceptance_criteria}

      **Use story_number: #{story.number}** when mapping this story to components.
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
