defmodule CodeMySpec.AgentTasks.ManageImplementation do
  @moduledoc """
  Orchestrates the implementation lifecycle of a project.

  Both command/3 and evaluate/3 converge on `dispatch/3`, which runs
  the core pipeline as a flat `with` block:

    resolve_story       → {:failing, story, failures} (continues)
    resolve_development → {:develop, component, task_module} (continues)
    dispatch_develop    → write status, return prompt

  Any step that doesn't match falls to the `else` clause:

    :complete                    → all done
    {:needs_specs, story}        → write BDD specs
    {:failing_unmapped, failures}→ specs fail but can't map to story
    {:fix_specs, story, failures}→ all reqs satisfied, specs still fail
    {:blocked, story, reason}    → deps unsatisfied, can't develop
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Components
  alias CodeMySpec.Components.DependencyTree
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Stories

  alias CodeMySpec.AgentTasks.{
    DevelopContext,
    DevelopController,
    DevelopLiveContext,
    DevelopLiveView,
    WriteBddSpecs
  }

  require Logger

  @status_path CodeMySpec.Paths.implementation_status_path()

  @developable_types [
    "context",
    "coordination_context",
    "controller",
    "live_context",
    "liveview",
    "liveview_component"
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, session, opts \\ []) do
    env = scope.environment

    with {:ok, _} <- maybe_sync_project(scope, env, opts) do
      case dispatch(env, scope, session) do
        :complete -> {:ok, all_complete_message(env)}
        {:ok, prompt} -> {:ok, prompt}
      end
    end
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, session, _opts \\ []) do
    env = scope.environment

    with {:ok, status} <- read_status(env),
         {:ok, :valid} <- evaluate_current_task(scope, session, env, status),
         :ok <- clear_status(env) do
      case dispatch(env, scope, session) do
        :complete -> {:ok, :valid}
        {:ok, prompt} -> {:ok, :invalid, prompt}
      end
    else
      {:ok, :invalid, feedback} ->
        {:ok, :invalid, feedback}

      {:error, :not_found} ->
        Logger.info("[Orchestrator] Evaluate: no active task")
        {:ok, :valid}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Logger.error("[ManageImplementation] Error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  # ============================================================================
  # Core Pipeline
  # ============================================================================

  defp dispatch(env, scope, session) do
    with {:failing, story, failures} <- resolve_story(env, scope),
         {:develop, component, task_module} <- resolve_development(scope, story, failures) do
      dispatch_develop(env, scope, session, story, component, task_module)
    else
      :complete -> :complete
      {:needs_specs, story} -> dispatch_write_specs(env, scope, session, story)
      {:failing_unmapped, failures} -> dispatch_unmapped(env, failures)
      {:fix_specs, story, failures} -> dispatch_fix_specs(env, story, failures)
      {:blocked, story, reason} -> dispatch_blocked(env, story, reason)
    end
  end

  # ============================================================================
  # Step 1: resolve_story
  # ============================================================================

  defp resolve_story(env, scope) do
    case run_bdd_specs(env) do
      {:ok, failures, exit_code} when exit_code != 0 or failures != [] ->
        Logger.info("[Orchestrator] BDD specs: #{length(failures)} failing (exit #{exit_code})")
        resolve_failing_story(env, scope, failures)

      _ ->
        Logger.info("[Orchestrator] BDD specs: all passing")
        resolve_next_story(env, scope)
    end
  end

  defp resolve_failing_story(env, scope, failures) do
    story_ids = derive_failing_story_ids(env, failures)
    stories = Stories.list_project_stories_by_priority(scope)

    case Enum.find(stories, &MapSet.member?(story_ids, &1.id)) do
      nil ->
        Logger.info("[Orchestrator] Cannot map failures to any story")
        {:failing_unmapped, failures}

      story ->
        Logger.info("[Orchestrator] Target story: \"#{story.title}\"")
        {:failing, story, failures}
    end
  end

  defp resolve_next_story(env, scope) do
    case BddSpecs.get_next_incomplete_story(env, scope) do
      %{} = story ->
        Logger.info("[Orchestrator] Next story needing specs: \"#{story.title}\"")
        {:needs_specs, story}

      nil ->
        Logger.info("[Orchestrator] All stories complete")
        :complete
    end
  end

  defp derive_failing_story_ids(env, failures) do
    ids =
      failures
      |> Enum.map(&failure_file_path/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Parser.derive_story_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # Fallback: compilation errors prevent JSONL output, derive from files on disk
    if MapSet.size(ids) == 0 do
      Environments.glob(env, "test/spex/**/*_spex.exs")
      |> Enum.map(&Parser.derive_story_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
    else
      ids
    end
  end

  defp failure_file_path(%{error: %{file: file}}) when is_binary(file), do: file
  defp failure_file_path(_), do: nil

  # ============================================================================
  # Step 2: resolve_development
  # ============================================================================

  defp resolve_development(scope, story, failures) do
    all_components = Components.list_components_with_dependencies(scope)
    component_map = Map.new(all_components, fn c -> {c.id, c} end)

    case Map.get(component_map, story.component_id) do
      nil ->
        Logger.info("[Orchestrator] Blocked: story has no linked component")
        {:blocked, story, "Story has no linked component"}

      target ->
        chain = build_dependency_chain(target, all_components, component_map)
        log_chain(chain, target)
        find_developable(chain, story, failures)
    end
  end

  defp find_developable(chain, story, failures) do
    developable =
      Enum.find(chain, fn c ->
        c.type in @developable_types and
          has_unsatisfied_requirements?(c) and
          dependencies_satisfied?(c)
      end)

    case developable do
      nil ->
        diagnose_chain(chain, story, failures)

      component ->
        Logger.info("[Orchestrator] Develop: #{component.module_name} (#{component.type})")
        {:develop, component, task_module_for(component)}
    end
  end

  # Distinguish "truly all satisfied" from "blocked by non-developable deps"
  defp diagnose_chain(chain, story, failures) do
    if Enum.any?(chain, &has_unsatisfied_requirements?/1) do
      Logger.info("[Orchestrator] Blocked: unsatisfied requirements but no developable target")
      {:blocked, story, format_blocked_diagnostics(chain)}
    else
      Logger.info("[Orchestrator] All requirements satisfied — specs failing, needs debugging")
      {:fix_specs, story, failures}
    end
  end

  # ============================================================================
  # Dispatch Handlers
  # ============================================================================

  defp dispatch_develop(env, scope, _session, story, component, task_module) do
    dev_session = %{component: component, project: scope.active_project}
    {:ok, prompt} = task_module.command(scope, dev_session)

    write_status(env, %{
      task: task_key(task_module),
      module_name: component.module_name,
      component_id: component.id,
      target_story_id: story.id
    })

    {:ok, wrap_prompt("Develop: #{component.name} (Story: #{story.title})", prompt)}
  end

  defp dispatch_write_specs(env, scope, session, story) do
    bdd_session = %{
      story_id: story.id,
      external_conversation_id: get_external_id(session)
    }

    {:ok, prompt} = WriteBddSpecs.command(scope, bdd_session, skip_sync: true)
    write_status(env, %{task: "write_bdd_specs", story_id: story.id})
    {:ok, wrap_prompt("Write BDD Specs: #{story.title}", prompt)}
  end

  defp dispatch_fix_specs(env, story, failures) do
    write_status(env, %{task: "fix_failing_specs", story_id: story.id})
    {:ok, wrap_prompt("Fix Failing Specs: #{story.title}", format_fix_prompt(story, failures))}
  end

  defp dispatch_blocked(env, story, reason) do
    clear_status(env)
    {:ok, wrap_prompt("Story Blocked: #{story.title}", "Cannot develop story: #{reason}")}
  end

  defp dispatch_unmapped(env, failures) do
    clear_status(env)
    failure_list = Enum.map_join(failures, "\n", fn f -> "- #{f.spex}: #{f.scenario}" end)

    {:ok,
     wrap_prompt(
       "BDD Specs Failing",
       """
       BDD specs are failing but cannot be mapped to any story.
       This may indicate a configuration issue or missing component-to-story mapping.

       Failing specs:
       #{failure_list}
       """
     )}
  end

  defp all_complete_message(env) do
    clear_status(env)
    "All stories are complete and all components are implemented. No further action needed."
  end

  # ============================================================================
  # Evaluate Current Task
  # ============================================================================

  defp evaluate_current_task(scope, session, _env, %{"task" => "write_bdd_specs"} = status) do
    Logger.info("[Orchestrator] Evaluate: write_bdd_specs")

    bdd_session = %{
      story_id: status["story_id"],
      external_conversation_id: get_external_id(session)
    }

    result = WriteBddSpecs.evaluate(scope, bdd_session)
    log_eval_result(result)
    result
  end

  defp evaluate_current_task(_scope, _session, env, %{
         "task" => "fix_failing_specs",
         "story_id" => story_id
       }) do
    Logger.info("[Orchestrator] Evaluate: fix_failing_specs")
    story_failures = get_story_failures(env, story_id)

    if story_failures == [] do
      Logger.info("[Orchestrator] Evaluate result: valid (specs passing)")
      {:ok, :valid}
    else
      Logger.info(
        "[Orchestrator] Evaluate result: invalid (#{length(story_failures)} failures remain)"
      )

      details =
        Enum.map_join(story_failures, "\n", fn f -> "- #{f.spex}: #{f.scenario}" end)

      {:ok, :invalid, "BDD specs are still failing. Keep debugging.\n\n#{details}"}
    end
  end

  defp evaluate_current_task(scope, _session, _env, %{
         "task" => task,
         "component_id" => component_id
       }) do
    component = Components.get_component(scope, component_id)
    task_module = task_module_from_key(task)
    Logger.info("[Orchestrator] Evaluate: #{task} (#{component.module_name})")

    dev_session = %{component: component, project: scope.active_project}
    result = task_module.evaluate(scope, dev_session)
    log_eval_result(result)
    result
  end

  defp log_eval_result({:ok, :valid}), do: Logger.info("[Orchestrator] Evaluate result: valid")

  defp log_eval_result({:ok, :invalid, _}),
    do: Logger.info("[Orchestrator] Evaluate result: invalid")

  defp log_eval_result({:error, r}),
    do: Logger.info("[Orchestrator] Evaluate result: error (#{inspect(r)})")

  defp get_story_failures(env, story_id) do
    case run_bdd_specs(env) do
      {:ok, failures, exit_code} when exit_code != 0 or failures != [] ->
        filter_story_failures(failures, story_id)

      _ ->
        []
    end
  end

  # ============================================================================
  # Task Module Mapping
  # ============================================================================

  defp task_module_for(%{type: "controller"}), do: DevelopController

  defp task_module_for(%{type: type})
       when type in ["context", "coordination_context"],
       do: DevelopContext

  defp task_module_for(%{type: "live_context"}), do: DevelopLiveContext

  defp task_module_for(%{type: type})
       when type in ["liveview", "liveview_component"],
       do: DevelopLiveView

  defp task_key(DevelopController), do: "develop_controller"
  defp task_key(DevelopContext), do: "develop_context"
  defp task_key(DevelopLiveContext), do: "develop_live_context"
  defp task_key(DevelopLiveView), do: "develop_live_view"

  defp task_module_from_key("develop_controller"), do: DevelopController
  defp task_module_from_key("develop_context"), do: DevelopContext
  defp task_module_from_key("develop_live_context"), do: DevelopLiveContext
  defp task_module_from_key("develop_live_view"), do: DevelopLiveView

  # ============================================================================
  # Dependency Chain Helpers
  # ============================================================================

  defp build_dependency_chain(target, all_components, component_map) do
    chain_ids =
      target
      |> collect_transitive_deps(component_map, MapSet.new())
      |> MapSet.put(target.id)

    all_components
    |> Enum.filter(fn c -> MapSet.member?(chain_ids, c.id) end)
    |> DependencyTree.build()
  end

  defp collect_transitive_deps(component, component_map, visited) do
    deps =
      case component.dependencies do
        %Ecto.Association.NotLoaded{} -> []
        deps -> deps
      end

    Enum.reduce(deps, visited, fn dep, acc ->
      collect_dep(dep, component_map, acc)
    end)
  end

  defp collect_dep(dep, component_map, visited) do
    if MapSet.member?(visited, dep.id) do
      visited
    else
      visited = MapSet.put(visited, dep.id)

      case Map.get(component_map, dep.id) do
        nil -> visited
        dep_component -> collect_transitive_deps(dep_component, component_map, visited)
      end
    end
  end

  defp has_unsatisfied_requirements?(component) do
    (component.requirements || [])
    |> Enum.any?(fn r -> not r.satisfied end)
  end

  defp dependencies_satisfied?(component) do
    dep_req =
      (component.requirements || [])
      |> Enum.find(fn r -> r.name == "dependencies_satisfied" end)

    is_nil(dep_req) or dep_req.satisfied
  end

  # ============================================================================
  # Diagnostics & Logging
  # ============================================================================

  defp log_chain(chain, target) do
    summary =
      Enum.map_join(chain, ", ", fn c ->
        unsatisfied = unsatisfied_requirement_names(c)
        developable? = c.type in @developable_types
        deps_ok? = dependencies_satisfied?(c)

        status =
          cond do
            unsatisfied == [] -> "ok"
            developable? and deps_ok? -> "READY"
            developable? -> "waiting-on-deps"
            true -> "non-developable"
          end

        "#{c.module_name}(#{c.type}:#{status})"
      end)

    Logger.info("[Orchestrator] Chain for #{target.module_name}: #{summary}")
  end

  defp format_blocked_diagnostics(chain) do
    diagnostics =
      chain
      |> Enum.flat_map(&diagnose_component/1)
      |> Enum.join("\n")

    if diagnostics == "" do
      "No developable component found in dependency chain"
    else
      "No developable component found in dependency chain.\n\nDiagnostics:\n#{diagnostics}"
    end
  end

  defp diagnose_component(component) do
    unsatisfied = unsatisfied_requirement_names(component)

    cond do
      unsatisfied == [] ->
        []

      component.type not in @developable_types ->
        [
          "- #{component.module_name} (#{component.type}): not a developable type but has " <>
            "unsatisfied requirements: #{Enum.join(unsatisfied, ", ")}. " <>
            "Consider ignoring this component in config.yml if it's auto-generated."
        ]

      not dependencies_satisfied?(component) ->
        [
          "- #{component.module_name} (#{component.type}): has unsatisfied requirements " <>
            "(#{Enum.join(unsatisfied, ", ")}) but its own dependencies are not yet satisfied"
        ]

      true ->
        []
    end
  end

  defp unsatisfied_requirement_names(component) do
    (component.requirements || [])
    |> Enum.reject(& &1.satisfied)
    |> Enum.map(& &1.name)
  end

  # ============================================================================
  # BDD Spec Execution
  # ============================================================================

  defp run_bdd_specs(env) do
    spec_files = Environments.glob(env, "test/spex/**/*_spex.exs")

    if Enum.empty?(spec_files) do
      {:ok, [], 0}
    else
      BddSpecs.run_specs(spec_files, project_root: env.cwd, quiet: true)
    end
  end

  # ============================================================================
  # Prompt Formatting
  # ============================================================================

  defp format_fix_prompt(story, failures) do
    relevant = filter_story_failures(failures, story.id)
    relevant = if relevant != [], do: relevant, else: failures

    failure_details =
      Enum.map_join(relevant, "\n", fn f ->
        "- #{f.spex}: #{f.scenario}"
      end)

    """
    All component requirements for story "#{story.title}" are satisfied, but BDD specs are still failing.
    The implementation has bugs that need to be fixed.

    ## Failing BDD Specs

    #{failure_details}

    ## Instructions

    1. Read the failing spec files to understand what behavior is expected
    2. Read the relevant implementation files (controllers, contexts, schemas)
    3. Debug and fix the implementation to make the failing specs pass
    4. Run `mix test` on the specific failing spec files to verify your fixes
    """
  end

  defp filter_story_failures(failures, story_id) do
    Enum.filter(failures, fn f ->
      case failure_file_path(f) do
        nil -> false
        path -> Parser.derive_story_id(path) == story_id
      end
    end)
  end

  defp wrap_prompt(heading, prompt) do
    """
    # #{heading}

    #{prompt}
    """
  end

  # ============================================================================
  # Status File I/O
  # ============================================================================

  defp read_status(env) do
    case Environments.read_file(env, @status_path) do
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp write_status(env, data) do
    :ok = Environments.write_file(env, @status_path, Jason.encode!(data))
  end

  defp clear_status(env) do
    Environments.delete_file(env, @status_path)
    :ok
  end

  # ============================================================================
  # Project Sync & Helpers
  # ============================================================================

  defp maybe_sync_project(scope, env, opts) do
    if Keyword.get(opts, :skip_sync, false) do
      {:ok, :skipped}
    else
      working_dir = get_working_dir(env)
      Logger.debug("[ManageImplementation] Syncing project from #{working_dir}")

      case Sync.sync_all(scope, base_dir: working_dir) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, {:sync_failed, reason}}
      end
    end
  end

  defp get_working_dir(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp get_working_dir(%{ref: %{working_dir: dir}}), do: dir
  defp get_working_dir(_), do: File.cwd!()

  defp get_external_id(%{external_conversation_id: id}) when is_binary(id), do: id
  defp get_external_id(_), do: Ecto.UUID.generate()
end
