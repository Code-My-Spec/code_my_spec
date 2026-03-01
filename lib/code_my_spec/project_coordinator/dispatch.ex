defmodule CodeMySpec.ProjectCoordinator.Dispatch do
  @moduledoc """
  Translates a `%Requirement{}` from NextActionable into a prompt (command)
  or validation pass (evaluate).

  Thin layer — loads the entity from the requirement's FK, builds a minimal
  session, delegates to the task module and ProjectCoordinator.

  ## Scope handling

  - `:local` — call `task_module.command/3` directly
  - `:children` — parent `command/3` + `orchestrate/3` on each actionable child
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  Dispatch a requirement to its task module for command generation.

  For `:local` scope, loads the entity and calls `task_module.command/3`.

  For `:children` scope, calls the parent task module's `command/3`, then
  calls `orchestrate/3` on each actionable child to generate prompt files.
  Returns the concatenated prompt.
  """
  @spec command(Requirement.t(), Scope.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(%Requirement{scope: :children} = req, scope, parent_session) do
    command_children(req, scope, parent_session)
  end

  def command(%Requirement{scope: :orchestrate} = req, scope, parent_session) do
    command_orchestrate(req, scope, parent_session)
  end

  def command(%Requirement{} = req, scope, parent_session) do
    command_local(req, scope, parent_session)
  end

  @doc """
  Evaluate a requirement by delegating to its task module's `evaluate/3`.

  For `:children` scope, Dispatch handles child orchestration directly:
  collects descendants, finds actionable work, runs `orchestrate/3` on each,
  and returns `:valid` when all children are complete or `:invalid` with feedback.
  """
  @spec evaluate(Requirement.t(), Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(%Requirement{scope: :children} = req, scope, _parent_session) do
    evaluate_children(req, scope)
  end

  def evaluate(%Requirement{} = req, scope, parent_session) do
    Logger.info("[Dispatch] evaluate :local #{req.name} → #{inspect(req.satisfied_by)}")
    session = build_session(req, scope, parent_session)
    req.satisfied_by.evaluate(scope, session)
  end

  # ----------------------------------------------------------------
  # Command: :local
  # ----------------------------------------------------------------

  defp command_local(req, scope, parent_session) do
    Logger.info("[Dispatch] command :local #{req.name} → #{inspect(req.satisfied_by)}")
    session = build_session(req, scope, parent_session)
    req.satisfied_by.command(scope, session, skip_sync: true)
  end

  # ----------------------------------------------------------------
  # Command: :orchestrate
  #
  # Like :local but writes a prompt file via default_orchestrate and
  # returns an orchestration prompt telling the main agent to invoke
  # a subagent.
  # ----------------------------------------------------------------

  defp command_orchestrate(req, scope, parent_session) do
    Logger.info("[Dispatch] command :orchestrate #{req.name} → #{inspect(req.satisfied_by)}")
    session = build_session(req, scope, parent_session)
    component = session.component
    status_dir = ProjectCoordinator.component_status_dir(component)

    {:ok, result} =
      ProjectCoordinator.default_orchestrate(req.satisfied_by, scope, session, status_dir: status_dir)

    orchestration = """
    # Orchestrate: #{component.module_name}

    ## Task Status
    #{result.orchestration_prompt}

    ## Instructions
    Read the prompt file at `#{result.prompt_path}` and invoke the appropriate subagent.
    When the task is complete, **stop the session** so the hook can validate.
    """

    {:ok, orchestration}
  end

  # ----------------------------------------------------------------
  # Command: :children
  #
  # 1. Call parent task module's command → parent_prompt
  # 2. Collect context + descendants
  # 3. Find actionable children
  # 4. For each: call task_module.orchestrate → writes prompt file, returns metadata
  # 5. Concatenate parent_prompt + orchestration checklist
  # ----------------------------------------------------------------

  defp command_children(req, scope, _parent_session) do
    Logger.info("[Dispatch] command :children #{req.name} → #{inspect(req.satisfied_by)}")
    context = Components.get_component!(scope, req.component_id)
    session = %{component: context, project: scope.active_project}

    {:ok, parent_prompt} = req.satisfied_by.command(scope, session)

    # collect_components returns context + all descendants; find_actionable
    # filters to only components with unsatisfied requirements (completed children skipped)
    components = ProjectCoordinator.collect_components(scope, context)
    actionable = ProjectCoordinator.find_actionable(scope, components)

    if Enum.empty?(actionable) do
      {:error, "#{req.name} unsatisfied but no actionable children found"}
    else
      status_dir = ProjectCoordinator.component_status_dir(context)

      results =
        Enum.map(actionable, fn %{component: child, task_module: task_module} ->
          child_session = %{component: child, project: scope.active_project}
          {:ok, result} = task_module.orchestrate(scope, child_session, status_dir: status_dir)
          result
        end)

      orchestration_lines = Enum.map_join(results, "\n", & &1.orchestration_prompt)

      orchestration = """
      # Development: #{context.name}

      ## Task Status

      #{orchestration_lines}

      ## Instructions

      For each incomplete task above, read the prompt file and invoke the appropriate subagent.
      When all tasks are complete, **stop the session** so the hook can validate.
      """

      {:ok, parent_prompt <> "\n\n" <> orchestration}
    end
  end

  # ----------------------------------------------------------------
  # Evaluate: :children
  #
  # 1. Load context + descendants
  # 2. Find actionable children
  # 3. If none → cleanup status dir → :valid
  # 4. For each: call task_module.orchestrate → check completeness
  # 5. All complete → cleanup → :valid; otherwise → :invalid with feedback
  # ----------------------------------------------------------------

  defp evaluate_children(req, scope) do
    Logger.info("[Dispatch] evaluate :children #{req.name}")
    context = ComponentRepository.get_component(scope, req.component_id)
    children = ComponentRepository.list_all_descendants(scope, context.id)
    status_dir = ProjectCoordinator.component_status_dir(context)
    working_dir = scope.environment && scope.environment.cwd

    actionable = ProjectCoordinator.find_actionable(scope, children)

    if Enum.empty?(actionable) do
      Logger.info("[Dispatch] evaluate :children #{context.module_name} → all children complete")
      ProjectCoordinator.cleanup_status_directory(status_dir, working_dir)
      {:ok, :valid}
    else
      results =
        Enum.map(actionable, fn %{component: child, task_module: task_module} ->
          child_session = %{component: child, project: scope.active_project}
          {:ok, result} = task_module.orchestrate(scope, child_session, status_dir: status_dir)
          result
        end)

      pending = Enum.reject(results, & &1.complete)

      if Enum.empty?(pending) do
        Logger.info("[Dispatch] evaluate :children #{context.module_name} → all orchestrated, complete")
        ProjectCoordinator.cleanup_status_directory(status_dir, working_dir)
        {:ok, :valid}
      else
        Logger.info("[Dispatch] evaluate :children #{context.module_name} → #{length(pending)} pending")
        feedback = Enum.map_join(results, "\n", & &1.orchestration_prompt)
        {:ok, :invalid, feedback}
      end
    end
  end

  # ----------------------------------------------------------------
  # Session building — minimal, just load the entity
  # ----------------------------------------------------------------

  defp build_session(%Requirement{story_id: sid} = _req, scope, parent_session)
       when not is_nil(sid) do
    story = Stories.get_story!(scope, sid)
    component = if story.component_id, do: Components.get_component!(scope, story.component_id)

    Map.merge(parent_session, %{
      story_id: story.id,
      state: %{"topic" => story.id},
      component: component,
      project: scope.active_project
    })
  end

  defp build_session(%Requirement{component_id: cid} = _req, scope, parent_session)
       when not is_nil(cid) do
    component = Components.get_component!(scope, cid)
    Map.merge(parent_session, %{component: component, project: scope.active_project})
  end

  defp build_session(%Requirement{project_id: pid} = _req, scope, parent_session)
       when not is_nil(pid) do
    Map.merge(parent_session, %{project: scope.active_project})
  end

  defp build_session(_req, _scope, parent_session), do: parent_session
end
