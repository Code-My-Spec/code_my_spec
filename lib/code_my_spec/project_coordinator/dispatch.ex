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
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.ProjectCoordinator.ImplementationStatus
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

  def command(%Requirement{scope: :pipeline} = req, scope, parent_session) do
    command_pipeline(req, scope, parent_session)
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

  def evaluate(%Requirement{scope: :pipeline} = req, scope, parent_session) do
    evaluate_pipeline(req, scope, parent_session)
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
        # default_orchestrate handles both component and project-scoped sessions
        ProjectCoordinator.default_orchestrate(task_module, scope, session, [])
      end

    record_orchestrate_task(scope, req, prompt_path: result[:prompt_path])

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
        Start a subagent with exactly this prompt:
        `#{result.prompt_path}`

        Do NOT read the file or write instructions around it — pass the path string as-is.
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
        # default_orchestrate_evaluate handles both component and project-scoped sessions
        {:ok, r} =
          ProjectCoordinator.default_orchestrate_evaluate(
            task_module,
            scope,
            session,
            []
          )

        {:ok, r, nil}
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
  # Command: :pipeline
  #
  # Bundles a requirement and its downstream dependents into a single
  # subagent invocation. Each stage gets its own prompt file; the
  # subagent receives a to-do list.
  # ----------------------------------------------------------------

  defp command_pipeline(req, scope, parent_session) do
    Logger.info("[Dispatch] command :pipeline #{req.name} → #{inspect(req.satisfied_by)}")

    chain = collect_pipeline_chain(req)
    Logger.info("[Dispatch] Pipeline chain: #{Enum.map_join(chain, " → ", & &1.name)}")

    session = build_session(req, scope, parent_session)

    # Generate prompt files for each stage
    stage_results =
      Enum.map(chain, fn stage_def ->
        task_module = stage_def.satisfied_by

        stage_req = %Requirement{
          name: stage_def.name,
          scope: :orchestrate,
          satisfied_by: task_module,
          component_id: req.component_id,
          story_id: req.story_id,
          project_id: req.project_id
        }

        {:ok, result} =
          if has_function?(task_module, :orchestrate, 3) do
            task_module.orchestrate(scope, session, [])
          else
            ProjectCoordinator.default_orchestrate(task_module, scope, session, [])
          end

        record_orchestrate_task(scope, stage_req, prompt_path: result[:prompt_path])

        {stage_def, result}
      end)

    # Build the pipeline to-do list
    pipeline_prompt_path = write_pipeline_prompt(scope, req, stage_results)

    checklist =
      stage_results
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{stage_def, result}, idx} ->
        "#{idx}. [ ] Read and complete: `#{result.prompt_path}` (#{stage_def.name})"
      end)

    subagent_type =
      stage_results
      |> List.first()
      |> elem(1)
      |> Map.get(:subagent_type, "codemyspec:qa")

    orchestration = """
    # Pipeline: #{req.name} (#{length(stage_results)} stages)

    Complete each stage in order. Stop the session after completing ALL stages.

    #{checklist}

    Start a #{subagent_type} subagent with exactly this prompt:
    `#{pipeline_prompt_path}`

    Do NOT read the file or write instructions around it — pass the path string as-is.
    """

    {:ok, orchestration}
  end

  defp write_pipeline_prompt(scope, req, stage_results) do
    env = scope.environment
    pipeline_path = ".code_my_spec/tasks/pipeline_#{req.name}.md"

    content =
      stage_results
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{stage_def, result}, idx} ->
        "## Stage #{idx}: #{stage_def.name}\n\nRead and complete: `#{result.prompt_path}`"
      end)

    prompt = """
    # Pipeline: #{req.name}

    Complete each stage in order. Do not skip stages.

    #{content}

    When all stages are complete, stop the session.
    """

    if env, do: Environments.write_file(env, pipeline_path, prompt)
    pipeline_path
  end

  # Collect the pipeline chain: starting from this requirement's definition,
  # follow downstream requirements where the current stage is a prerequisite.
  defp collect_pipeline_chain(%Requirement{} = req) do
    # Get all definitions for this entity type
    all_defs = get_entity_definitions(req)
    start_def = Enum.find(all_defs, &(&1.name == req.name))

    if start_def do
      collect_chain_forward([start_def], all_defs)
    else
      []
    end
  end

  defp collect_chain_forward(chain, all_defs) do
    current = List.last(chain)

    # Find the next definition that lists current.name as a prerequisite
    # and has :orchestrate scope (pipeline stages are individually :orchestrate)
    next =
      Enum.find(all_defs, fn defn ->
        defn.name != current.name &&
          current.name in defn.prerequisites &&
          defn.scope in [:orchestrate, :pipeline] &&
          defn not in chain
      end)

    if next do
      collect_chain_forward(chain ++ [next], all_defs)
    else
      chain
    end
  end

  defp get_entity_definitions(%Requirement{project_id: pid}) when not is_nil(pid) do
    CodeMySpec.Requirements.RequirementDefinitionData.project_requirements()
  end

  defp get_entity_definitions(%Requirement{story_id: sid}) when not is_nil(sid) do
    CodeMySpec.Requirements.RequirementDefinitionData.story_requirements()
  end

  defp get_entity_definitions(_req), do: []

  # ----------------------------------------------------------------
  # Evaluate: :pipeline
  #
  # Evaluates each stage in order. Returns :valid only when ALL pass.
  # Returns :invalid with first failure's feedback.
  # ----------------------------------------------------------------

  defp evaluate_pipeline(req, scope, parent_session) do
    Logger.info("[Dispatch] evaluate :pipeline #{req.name}")

    chain = collect_pipeline_chain(req)
    session = build_session(req, scope, parent_session)

    Enum.reduce_while(chain, {:ok, :valid}, fn stage_def, _acc ->
      task_module = stage_def.satisfied_by

      result =
        if has_function?(task_module, :orchestrate_evaluate, 3) do
          task_module.orchestrate_evaluate(scope, session, [])
        else
          ProjectCoordinator.default_orchestrate_evaluate(task_module, scope, session, [])
        end

      case result do
        {:ok, %{complete: true}} ->
          Logger.info("[Dispatch] Pipeline stage #{stage_def.name} → complete")
          {:cont, {:ok, :valid}}

        {:ok, %{complete: false} = r} ->
          Logger.info("[Dispatch] Pipeline stage #{stage_def.name} → incomplete")

          feedback =
            "Read your updated instructions at `#{r.problem_path}` and continue.\n" <>
              "When done, **stop the session** so the hook can validate."

          {:halt, {:ok, :invalid, feedback}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
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
      Enum.map(actionable, fn %{component: child, task_module: task_module} = action ->
        child_session = %{component: child, project: scope.active_project}
        {:ok, result} = task_module.orchestrate(scope, child_session, status_dir: status_dir)
        record_child_task(scope, child, action, result[:prompt_path])
        result
      end)

    orchestration_lines = Enum.map_join(results, "\n", & &1.orchestration_prompt)

    prompt_instructions =
      results
      |> Enum.filter(& &1[:prompt_path])
      |> Enum.map_join("\n", fn r ->
        subagent_type = Map.get(r, :subagent_type, "codemyspec:code-writer")

        "Start a #{subagent_type} subagent with exactly this prompt:\n`#{r.prompt_path}`\n\nDo NOT read the file or write instructions around it — pass the path string as-is."
      end)

    orchestration = """
    # Development: #{component.name}

    ## Task Status

    #{orchestration_lines}

    ## Instructions

    #{prompt_instructions}
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
        Logger.info(
          "[Dispatch] evaluate :children #{component.module_name} → parent evaluate valid"
        )

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

          orchestrate_children_eval(
            scope,
            dep_context,
            dep_actionable,
            dep_status_dir,
            working_dir
          )

        :complete ->
          Logger.info(
            "[Dispatch] evaluate :children #{component.module_name} → no actionable anywhere"
          )

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
      Logger.info(
        "[Dispatch] evaluate :children #{context.module_name} → all orchestrated, complete"
      )

      ProjectCoordinator.cleanup_status_directory(status_dir, working_dir)
      {:ok, :valid}
    else
      Logger.info(
        "[Dispatch] evaluate :children #{context.module_name} → #{length(pending)} pending"
      )

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
  # Status file — record dispatched tasks
  # ----------------------------------------------------------------

  defp record_orchestrate_task(scope, %Requirement{} = req, opts) do
    env = scope.environment

    if env do
      component = if req.component_id, do: Components.get_component!(scope, req.component_id)

      entry =
        ImplementationStatus.build_task_entry(req, component, scope.active_project,
          prompt_path: Keyword.get(opts, :prompt_path)
        )

      ImplementationStatus.record_task(env, entry)
    end
  end

  defp record_child_task(scope, child, %{definitions: definitions}, prompt_path) do
    env = scope.environment

    if env do
      req_name =
        case definitions do
          [first | _] -> first.name
          _ -> "unknown"
        end

      entry = %{
        "requirement" => req_name,
        "component_id" => child.id,
        "component_module" => child.module_name,
        "expected_files" =>
          ImplementationStatus.expected_files_for(
            %Requirement{name: req_name, scope: :local},
            child,
            scope.active_project
          ),
        "dispatched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      entry = if prompt_path, do: Map.put(entry, "prompt_path", prompt_path), else: entry
      ImplementationStatus.record_task(env, entry)
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
