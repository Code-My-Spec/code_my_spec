defmodule CodeMySpec.AgentTasks.ArchitectureDesign do
  @moduledoc """
  Map user stories to application components via proposal + MCP-tool mutations.
  """

  alias CodeMySpec.Architecture.Proposal
  alias CodeMySpec.{Components, Paths, Stories}
  alias CodeMySpec.Documents.DocumentSpecProjector
  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

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

    # The caller's environment or none. Inventing one at this server's
    # directory made `proposal_exists?` answer about *this* repository.
    env = scope.environment || cli_env(working_dir)

    proposal_exists? = revision_mode?(env, component_count)

    record_session_start_state(env, proposal_exists?)

    prompt = build_prompt(project, stories, component_count, proposal_exists?)

    {:ok, prompt}
  end

  # Revision when there is an architecture to revise, whatever became of the
  # file that first described it.
  #
  # `proposal.md`'s presence used to be the entire decision, and that file is an
  # artifact of how the architecture was *first* produced rather than a
  # description of its current state. A project with 912 components has been
  # designed; whether anyone kept — or ever wrote, or has since deleted — the
  # proposal that designed it is a different question. Answering the first with
  # the second is what put "The project has 910 existing components" eleven
  # lines above "Mode — initial. No proposal exists yet."
  #
  # Component count alone, not "components *and* every story linked" as the
  # report suggested: unlinked stories on an existing architecture still want
  # revision's tools — `set_story_component` against what is already there —
  # and initial mode would answer them by redesigning the project.
  #
  # The file still means something when there are no components: "there is no
  # proposal to patch". It just never again means "there is no architecture".
  #
  # Note the stat is skipped entirely once components exist, which is both the
  # common case and the one where the environment is most likely to be a harness
  # on the far end of a channel.
  defp revision_mode?(_env, component_count) when component_count > 0, do: true

  defp revision_mode?(env, _component_count) do
    case proposal_status(env) do
      :present ->
        true

      :absent ->
        false

      # Could not look. Reported as *present*, because the two answers are not
      # symmetric: treating an unreadable environment as "no proposal" selects
      # initial mode, which tells the agent to design the architecture end-to-end
      # and has the evaluator execute the result as one transaction. Treating it
      # as "proposal present" selects revision mode, whose worst case is an agent
      # making no incremental edits.
      #
      # This is exactly what `Environments`' own moduledoc warns about: "no disk"
      # and "not there" are the same reply from `file_exists?/2`, "which is fine
      # for rendering a prompt and is *not* fine for deciding a requirement is
      # unmet". Choosing the mode is deciding.
      #
      # Observed: `proposal.md` was on disk, 8KB, and the prompt said "Mode —
      # initial. No proposal exists yet." The harness was unreachable at that
      # moment, `request/3` answered `{:error, :harness_unreachable}`, and
      # `match?({:ok, _}, ...)` turned it into `false`.
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

  # Same asymmetry as `proposal_status/1`, and the same resolution. The guard on
  # `evaluate/2` below catches a nil environment because that decided *initial*
  # — the branch that rewrites the proposal end-to-end — but an environment that
  # exists and cannot be read reaches here and decides the same way.
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
  # No disk, no answer. `patch_mode?/1` is a `file_exists?/2` call, and that
  # returns `false` for "no environment" exactly as it does for "not there" —
  # the asymmetry `Environments`' moduledoc warns about. So a nil environment
  # did not merely fail to decide the mode, it decided *initial*, which is the
  # branch that rewrites the proposal end-to-end. Refuse before the guess.
  def evaluate(%{environment: nil}, _task), do: {:error, :no_environment}

  def evaluate(scope, task) do
    env = scope.environment

    # Don't clear the marker on evaluate — `command/2` owns the lifecycle.
    # A failing patch-mode evaluate (e.g. unlinked story) used to clear the
    # marker and silently promote the next evaluate to full proposal
    # validation, forcing the architect to hand-edit proposal.md after
    # any DB-side fix. The marker survives until the next `start_task`,
    # which re-records based on proposal existence.
    if patch_mode?(env) do
      evaluate_patch_mode(scope, task)
    else
      evaluate_initial_mode(scope, env)
    end
  end

  # Patch mode: an architecture already exists and the architect used the
  # incremental tools without rewriting the proposal. A task for one story's
  # `component_linked` is done when that story has a component; other stories
  # are their own tasks, and orphans are not a gate (John, 2026-10-02).
  defp evaluate_patch_mode(scope, %{story_id: story_id}) when not is_nil(story_id) do
    case Stories.get_story(scope, story_id) do
      %{component_id: nil} = story -> {:ok, :invalid, unlinked_story_feedback(story)}
      _linked_or_gone -> {:ok, :valid}
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
    evaluate_initial_mode(scope, scope.environment)
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

      # "Could not look" is not "unmet". Flattened into `:invalid` it became the
      # gate's whole answer — `Blocking: Error: :no_environment`, naming no task,
      # no working copy and no way out — and it bypassed the branch built for
      # precisely this in `TaskEvaluator`, because that branch matches
      # `{:error, reason}` and this had already turned it into a verdict (074b7c83).
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

  # `file_exists?/2` cannot answer this, by documented design: it returns
  # `false` both for "not there" and for "no disk to look at". `stat` can, and
  # the same `Environments` moduledoc points at `Setup.Context.dir_status/2` as
  # the pattern for a caller that must tell them apart.
  #
  # `nil` env is genuinely absent rather than unobservable: it means this server
  # holds no working copy for the project, which is a known state, not a failed
  # read.
  defp proposal_status(nil), do: :absent

  defp proposal_status(env) do
    case Environments.stat(env, @proposal_path) do
      {:ok, _} -> :present
      {:error, :enoent} -> :absent
      {:error, _reason} -> :unobservable
    end
  end

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

  defp build_prompt(project, stories, component_count, proposal_exists?) do
    stories_section = format_stories(stories)
    app_name = get_app_name(project)

    architecture_section =
      if component_count > 0 do
        """
        ## Current Architecture

        The project has #{component_count} existing components. Read them:

        - `show_architecture_overview` for the whole graph
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
