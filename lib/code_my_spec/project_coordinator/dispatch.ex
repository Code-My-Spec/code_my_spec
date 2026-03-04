defmodule CodeMySpec.ProjectCoordinator.Dispatch do
  @moduledoc """
  Translates a `%Requirement{}` from NextActionable into a prompt (command)
  or validation pass (evaluate).

  Thin layer — loads the entity from the requirement's FK, builds a minimal
  session, delegates to the task module and ProjectCoordinator.

  ## Scope handling

  - `:local` — call `task_module.command/3` / `evaluate/3` directly
  - `:orchestrate` — write prompt/problems files via `default_orchestrate` / `default_orchestrate_evaluate`
  - `:children` — parent `command/3` + `orchestrate/3` / `orchestrate_evaluate/3` on each actionable child
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
  collects descendants, finds actionable work, runs `orchestrate_evaluate/3` on each,
  and returns `:valid` when all children are complete or `:invalid` with feedback.

  For `:orchestrate` scope, calls `default_orchestrate_evaluate` to check status
  and write/cleanup problems files. Returns structured feedback pointing to the
  problems file rather than inline text.
  """
  @spec evaluate(Requirement.t(), Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(%Requirement{scope: :children} = req, scope, _parent_session) do
    evaluate_children(req, scope)
  end

  def evaluate(%Requirement{scope: :orchestrate} = req, scope, parent_session) do
    evaluate_orchestrate(req, scope, parent_session)
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
    task_module = req.satisfied_by
    session = build_session(req, scope, parent_session)

    {:ok, result} =
      if has_function?(task_module, :orchestrate, 3) do
        task_module.orchestrate(scope, session, [])
      else
        component = session.component
        status_dir = ProjectCoordinator.component_status_dir(component)
        ProjectCoordinator.default_orchestrate(task_module, scope, session, status_dir: status_dir)
      end

    # Task module can provide full orchestration text via :orchestration key;
    # otherwise fall back to the generic template.
    orchestration =
      Map.get_lazy(result, :orchestration, fn ->
        label = orchestrate_label(session)

        """
        # Orchestrate: #{label}

        ## Task Status
        #{result.orchestration_prompt}

        ## Instructions
        Read the prompt file at `#{result.prompt_path}` and invoke the appropriate subagent.
        When the task is complete, **stop the session** so the hook can validate.
        """
      end)

    {:ok, orchestration}
  end

  # ----------------------------------------------------------------
  # Evaluate: :orchestrate
  #
  # Like evaluate :local but writes a problems file via
  # default_orchestrate_evaluate and returns structured feedback
  # pointing to the file.
  # ----------------------------------------------------------------

  defp evaluate_orchestrate(req, scope, parent_session) do
    Logger.info("[Dispatch] evaluate :orchestrate #{req.name} → #{inspect(req.satisfied_by)}")
    task_module = req.satisfied_by
    session = build_session(req, scope, parent_session)
    working_dir = scope.environment && scope.environment.cwd

    {:ok, result, cleanup_dir} =
      if has_function?(task_module, :orchestrate_evaluate, 3) do
        {:ok, r} = task_module.orchestrate_evaluate(scope, session, [])
        {:ok, r, nil}
      else
        component = session.component
        status_dir = ProjectCoordinator.component_status_dir(component)

        {:ok, r} =
          ProjectCoordinator.default_orchestrate_evaluate(
            task_module,
            scope,
            session,
            status_dir: status_dir
          )

        {:ok, r, status_dir}
      end

    if result.complete do
      Logger.info("[Dispatch] evaluate :orchestrate #{req.name} → complete")
      if cleanup_dir, do: ProjectCoordinator.cleanup_status_directory(cleanup_dir, working_dir)
      {:ok, :valid}
    else
      Logger.info("[Dispatch] evaluate :orchestrate #{req.name} → incomplete")

      {:ok, :invalid,
       "Read your updated instructions at `#{result.problem_path}` and continue.\n" <>
         "When done, **stop the session** so the hook can validate."}
    end
  end

  # ----------------------------------------------------------------
  # Command: :children
  #
  # 1. Resolve component (from req.component_id or story.component_id)
  # 2. Call parent task module's command → parent_prompt
  # 3. Collect component + descendants, find actionable children
  # 4. If no actionable: check dependency contexts for work
  # 5. For each: call task_module.orchestrate → writes prompt file, returns metadata
  # 6. Concatenate parent_prompt + orchestration checklist
  # ----------------------------------------------------------------

  @container_types ["context", "coordination_context", "live_context"]

  defp command_children(req, scope, _parent_session) do
    Logger.info("[Dispatch] command :children #{req.name} → #{inspect(req.satisfied_by)}")
    component = resolve_children_component(req, scope)
    session = %{component: component, project: scope.active_project}

    {:ok, parent_prompt} = req.satisfied_by.command(scope, session)

    # collect_components returns component + all descendants; find_actionable
    # filters to only components with unsatisfied requirements (completed children skipped)
    components = ProjectCoordinator.collect_components(scope, component)
    actionable = ProjectCoordinator.find_actionable(scope, components)

    if Enum.empty?(actionable) do
      # Surface component blocked — find first unsatisfied dependency context
      case find_actionable_dependency_context(scope, component) do
        {:ok, dep_context, dep_actionable} ->
          orchestrate_context(scope, dep_context, dep_actionable, parent_prompt)

        :complete ->
          {:error, "#{req.name} unsatisfied but no actionable children found"}
      end
    else
      orchestrate_context(scope, component, actionable, parent_prompt)
    end
  end

  defp orchestrate_context(scope, component, actionable, parent_prompt) do
    status_dir = ProjectCoordinator.component_status_dir(component)

    results =
      Enum.map(actionable, fn %{component: child, task_module: task_module} ->
        child_session = %{component: child, project: scope.active_project}
        {:ok, result} = task_module.orchestrate(scope, child_session, status_dir: status_dir)
        result
      end)

    orchestration_lines = Enum.map_join(results, "\n", & &1.orchestration_prompt)

    orchestration = """
    # Development: #{component.name}

    ## Task Status

    #{orchestration_lines}

    ## Instructions

    For each incomplete task above, read the prompt file and invoke the appropriate subagent.
    When all tasks are complete, **stop the session** so the hook can validate.
    """

    {:ok, parent_prompt <> "\n\n" <> orchestration}
  end

  # ----------------------------------------------------------------
  # Evaluate: :children
  #
  # 1. Load context + descendants
  # 2. Find actionable children
  # 3. If none → cleanup status dir → :valid
  # 4. For each: call task_module.orchestrate_evaluate → check completeness
  # 5. All complete → cleanup → :valid; otherwise → :invalid with feedback
  # ----------------------------------------------------------------

  defp evaluate_children(req, scope) do
    Logger.info("[Dispatch] evaluate :children #{req.name}")
    component = resolve_children_component(req, scope)
    session = %{component: component, project: scope.active_project}
    status_dir = ProjectCoordinator.component_status_dir(component)
    working_dir = scope.environment && scope.environment.cwd

    # Check the parent requirement's evaluate first — it's the authoritative
    # check for this specific requirement (e.g. children_designs only checks
    # spec_file, not code/test). If satisfied, clean up and return.
    case req.satisfied_by.evaluate(scope, session) do
      {:ok, :valid} ->
        Logger.info("[Dispatch] evaluate :children #{component.module_name} → parent evaluate valid")
        ProjectCoordinator.cleanup_status_directory(status_dir, working_dir)
        {:ok, :valid}

      _ ->
        orchestrate_evaluate_with_deps(scope, component, status_dir, working_dir)
    end
  end

  # Evaluate children with dependency context fallback.
  # First tries the surface component's own tree, then falls back to dependency contexts.
  defp orchestrate_evaluate_with_deps(scope, component, status_dir, working_dir) do
    components = ProjectCoordinator.collect_components(scope, component)
    actionable = ProjectCoordinator.find_actionable(scope, components)

    if Enum.empty?(actionable) do
      # Surface has no actionable work — check dependency contexts
      case find_actionable_dependency_context(scope, component) do
        {:ok, dep_context, dep_actionable} ->
          dep_status_dir = ProjectCoordinator.component_status_dir(dep_context)
          orchestrate_children_eval(scope, dep_context, dep_actionable, dep_status_dir, working_dir)

        :complete ->
          Logger.info("[Dispatch] evaluate :children #{component.module_name} → no actionable anywhere")
          ProjectCoordinator.cleanup_status_directory(status_dir, working_dir)
          {:ok, :valid}
      end
    else
      orchestrate_children_eval(scope, component, actionable, status_dir, working_dir)
    end
  end

  defp orchestrate_children_eval(scope, component, actionable, status_dir, working_dir) do
    results =
      Enum.map(actionable, fn %{component: child, task_module: task_module} ->
        child_session = %{component: child, project: scope.active_project}

        {:ok, result} =
          task_module.orchestrate_evaluate(scope, child_session, status_dir: status_dir)

        result
      end)

    evaluate_orchestration_results(results, component, status_dir, working_dir)
  end

  defp evaluate_orchestration_results(results, context, status_dir, working_dir) do
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

  # ----------------------------------------------------------------
  # Component resolution for :children scope
  # ----------------------------------------------------------------

  defp resolve_children_component(%Requirement{component_id: cid}, scope) when not is_nil(cid) do
    Components.get_component!(scope, cid)
  end

  defp resolve_children_component(%Requirement{story_id: sid}, scope) when not is_nil(sid) do
    story = Stories.get_story!(scope, sid)
    Components.get_component!(scope, story.component_id)
  end

  # Find the first dependency context with actionable work.
  # Filters dependencies to container types only (context, coordination_context, live_context).
  defp find_actionable_dependency_context(scope, component) do
    all_components = Components.list_components_with_dependencies(scope)
    component_with_deps = Enum.find(all_components, &(&1.id == component.id))

    deps =
      case component_with_deps do
        %{dependencies: %Ecto.Association.NotLoaded{}} -> []
        %{dependencies: deps} -> deps
        _ -> []
      end

    dep_contexts =
      deps
      |> Enum.map(fn dep -> Enum.find(all_components, &(&1.id == dep.id)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.type in @container_types))

    Enum.find_value(dep_contexts, :complete, fn dep_context ->
      components = ProjectCoordinator.collect_components(scope, dep_context)
      actionable = ProjectCoordinator.find_actionable(scope, components)

      if Enum.empty?(actionable), do: nil, else: {:ok, dep_context, actionable}
    end)
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

  # function_exported? returns false for unloaded modules; ensure_loaded first.
  defp has_function?(module, function, arity) do
    Code.ensure_loaded(module)
    function_exported?(module, function, arity)
  end

  # Label for the orchestration header — component module_name or story ID fallback
  defp orchestrate_label(%{component: %{module_name: name}}) when is_binary(name), do: name
  defp orchestrate_label(%{story_id: sid}) when not is_nil(sid), do: "Story #{sid}"
  defp orchestrate_label(_session), do: "Task"
end
