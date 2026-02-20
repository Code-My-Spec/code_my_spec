defmodule CodeMySpec.AgentTasks.ManageImplementation do
  @moduledoc """
  State machine that orchestrates the full implementation lifecycle of a project.

  Instead of generating a master prompt and asking the LLM to reason about
  component ordering and slash commands, this module directly delegates to
  WriteBddSpecs, DevelopContext, and DevelopLiveView, tracks the current task
  via a status file, and returns delegated prompts directly.

  The orchestration is **story-focused** and driven by BDD spec results:

    1. Run all BDD specs globally
    2. If specs are **failing** → map failures to stories → find the highest-priority
       failing story → develop its component chain in dependency order
    3. If specs are **passing** → find the next story needing BDD spec coverage → write specs
    4. If all stories have passing specs and full coverage → done

  This creates an interleaved loop: write specs for one story, develop until
  those specs pass, then write specs for the next story. Development stays
  focused on a single story at a time.

  State transitions:

    command/3 (session start):
      sync → run BDD specs → decide next task → delegate → write status → return prompt

    evaluate/3 (stop hook):
      read status → evaluate delegated task
      → invalid? → pass through feedback (keep working)
      → valid?  → run BDD specs → decide next task → delegate or complete
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Components
  alias CodeMySpec.Components.DependencyTree
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Stories

  alias CodeMySpec.AgentTasks.{DevelopContext, DevelopLiveView, WriteBddSpecs}

  require Logger

  @status_path "docs/status/implementation_status.json"

  @developable_types ["context", "coordination_context", "controller", "liveview", "liveview_component"]

  # ============================================================================
  # Public API
  # ============================================================================

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, session, opts \\ []) do
    env = scope.environment
    working_dir = get_working_dir(env)

    with {:ok, _sync_result} <- maybe_sync_project(scope, working_dir, opts) do
      dispatch_next_task(env, scope, session)
    end
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, session, opts \\ []) do
    env = scope.environment

    case read_status(env) do
      {:ok, %{"task" => "write_bdd_specs"} = status} ->
        bdd_session = %{
          story_id: status["story_id"],
          external_conversation_id: get_external_id(session)
        }

        evaluate_and_advance(scope, session, env, WriteBddSpecs, bdd_session, opts)

      {:ok, %{"task" => task, "component_id" => component_id}} ->
        component = Components.get_component(scope, component_id)
        task_module = task_module_from_key(task)
        dev_session = %{component: component, project: scope.active_project}
        evaluate_and_advance(scope, session, env, task_module, dev_session, opts)

      {:error, :not_found} ->
        # No status file — nothing in progress
        {:ok, :valid}
    end
  rescue
    exception ->
      Logger.error("[ManageImplementation] Error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  # ============================================================================
  # Orchestration Decision (BDD-spec driven, story-focused)
  # ============================================================================

  defp decide_next_task(env, scope) do
    case run_bdd_specs(env) do
      {:ok, failures, exit_code} when exit_code != 0 or failures != [] ->
        decide_on_failing_specs(env, scope, failures)

      {:ok, _failures, _exit_code} ->
        decide_on_passing_specs(env, scope)

      {:error, _reason} ->
        decide_on_passing_specs(env, scope)
    end
  end

  defp decide_on_failing_specs(env, scope, failures) do
    # Map failures to story IDs from parsed failure details
    failing_story_ids =
      failures
      |> Enum.map(fn f -> Parser.derive_story_id(f.spex) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # Fallback: if no story IDs from failures (e.g., compilation errors that
    # prevent JSONL output), derive from spec files that exist on disk
    failing_story_ids =
      if MapSet.size(failing_story_ids) == 0 do
        Environments.glob(env, "test/spex/**/*_spex.exs")
        |> Enum.map(&Parser.derive_story_id/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
      else
        failing_story_ids
      end

    # Find the highest-priority story among those with failing specs
    stories = Stories.list_project_stories_by_priority(scope)

    target_story =
      Enum.find(stories, fn story ->
        MapSet.member?(failing_story_ids, story.id)
      end)

    case target_story do
      nil ->
        {:specs_failing_no_target, failures}

      story ->
        case find_next_developable_for_story(scope, story) do
          {:develop, _story, _component, _task_module} = result -> result
          {:story_blocked, _story, _reason} = result -> result
        end
    end
  end

  defp decide_on_passing_specs(env, scope) do
    case BddSpecs.get_next_incomplete_story(env, scope) do
      %{} = story -> {:write_bdd_specs, story}
      nil -> :all_complete
    end
  end

  # ============================================================================
  # Story-Focused Component Finding
  # ============================================================================

  defp find_next_developable_for_story(scope, story) do
    all_components = Components.list_components_with_dependencies(scope)
    component_map = Map.new(all_components, fn c -> {c.id, c} end)

    case Map.get(component_map, story.component_id) do
      nil ->
        {:story_blocked, story, "Story has no linked component"}

      target ->
        # Collect the transitive dependency chain for this story's component
        chain_ids = collect_transitive_deps(target, component_map, MapSet.new())
        chain_ids = MapSet.put(chain_ids, target.id)

        # Filter all_components to just this chain, then topologically sort
        chain_components =
          all_components
          |> Enum.filter(fn c -> MapSet.member?(chain_ids, c.id) end)
          |> DependencyTree.build()

        # Find first developable component with unsatisfied requirements
        # whose own dependencies are satisfied
        developable =
          Enum.find(chain_components, fn c ->
            c.type in @developable_types and
              has_unsatisfied_requirements?(c) and
              dependencies_satisfied?(c)
          end)

        case developable do
          nil ->
            {:story_blocked, story, "No developable component found in dependency chain"}

          component ->
            {:develop, story, component, task_module_for_component(component)}
        end
    end
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
    requirements = component.requirements || []
    Enum.any?(requirements, fn r -> not r.satisfied end)
  end

  defp dependencies_satisfied?(component) do
    requirements = component.requirements || []

    dep_req =
      Enum.find(requirements, fn r ->
        r.name == "dependencies_satisfied"
      end)

    # If there's no dependencies_satisfied requirement, deps are trivially satisfied.
    # If it exists, it must be satisfied.
    is_nil(dep_req) or dep_req.satisfied
  end

  # ============================================================================
  # Dispatch
  # ============================================================================

  defp dispatch_next_task(env, scope, session) do
    case decide_next_task(env, scope) do
      {:write_bdd_specs, story} ->
        bdd_session = %{
          story_id: story.id,
          external_conversation_id: get_external_id(session)
        }

        {:ok, prompt} = WriteBddSpecs.command(scope, bdd_session, skip_sync: true)
        write_status(env, %{task: "write_bdd_specs", story_id: story.id})
        {:ok, wrap_prompt("Write BDD Specs: #{story.title}", prompt)}

      {:develop, story, component, task_module} ->
        dev_session = %{component: component, project: scope.active_project}
        {:ok, prompt} = task_module.command(scope, dev_session)

        write_status(env, %{
          task: task_key(task_module),
          module_name: component.module_name,
          component_id: component.id,
          target_story_id: story.id
        })

        {:ok, wrap_prompt("Develop: #{component.name} (Story: #{story.title})", prompt)}

      {:specs_failing_no_target, failures} ->
        clear_status(env)
        {:ok, wrap_prompt("BDD Specs Failing", format_failure_details(failures))}

      {:story_blocked, story, reason} ->
        clear_status(env)

        {:ok,
         wrap_prompt(
           "Story Blocked: #{story.title}",
           "Cannot develop story: #{reason}"
         )}

      :all_complete ->
        clear_status(env)

        {:ok,
         "All stories are complete and all components are implemented. No further action needed."}
    end
  end

  # ============================================================================
  # Task Module Mapping
  # ============================================================================

  defp task_module_for_component(%{type: type})
       when type in ["context", "coordination_context", "controller"],
       do: DevelopContext

  defp task_module_for_component(%{type: type})
       when type in ["liveview", "liveview_component"],
       do: DevelopLiveView

  defp task_key(DevelopContext), do: "develop_context"
  defp task_key(DevelopLiveView), do: "develop_live_view"

  defp task_module_from_key("develop_context"), do: DevelopContext
  defp task_module_from_key("develop_live_view"), do: DevelopLiveView

  # ============================================================================
  # Evaluate and Advance
  # ============================================================================

  defp evaluate_and_advance(scope, session, env, task_module, delegate_session, _opts) do
    case task_module.evaluate(scope, delegate_session) do
      {:ok, :valid} ->
        # Delegated task done — run BDD specs to decide what's next
        clear_status(env)

        case decide_next_task(env, scope) do
          :all_complete ->
            {:ok, :valid}

          next_task ->
            # Advance to the next task
            {:ok, :invalid, dispatch_advance(env, scope, session, next_task)}
        end

      {:ok, :invalid, feedback} ->
        {:ok, :invalid, feedback}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_advance(env, scope, session, {:write_bdd_specs, story}) do
    bdd_session = %{
      story_id: story.id,
      external_conversation_id: get_external_id(session)
    }

    {:ok, prompt} = WriteBddSpecs.command(scope, bdd_session, skip_sync: true)
    write_status(env, %{task: "write_bdd_specs", story_id: story.id})
    wrap_prompt("Write BDD Specs: #{story.title}", prompt)
  end

  defp dispatch_advance(env, scope, _session, {:develop, story, component, task_module}) do
    dev_session = %{component: component, project: scope.active_project}
    {:ok, prompt} = task_module.command(scope, dev_session)

    write_status(env, %{
      task: task_key(task_module),
      module_name: component.module_name,
      component_id: component.id,
      target_story_id: story.id
    })

    wrap_prompt("Develop: #{component.name} (Story: #{story.title})", prompt)
  end

  defp dispatch_advance(env, _scope, _session, {:specs_failing_no_target, failures}) do
    clear_status(env)
    wrap_prompt("BDD Specs Failing", format_failure_details(failures))
  end

  defp dispatch_advance(env, _scope, _session, {:story_blocked, story, reason}) do
    clear_status(env)
    wrap_prompt("Story Blocked: #{story.title}", "Cannot develop story: #{reason}")
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

  defp format_failure_details(failures) do
    failure_list =
      Enum.map_join(failures, "\n", fn f -> "- #{f.spex}: #{f.scenario}" end)

    """
    BDD specs are failing but no component in the target story's dependency chain is ready for development.
    This may indicate a configuration issue or missing component-to-story mapping.

    Failing specs:
    #{failure_list}
    """
  end

  # ============================================================================
  # Status File I/O
  # ============================================================================

  defp read_status(env) do
    case Environments.read_file(env, @status_path) do
      {:ok, content} ->
        {:ok, Jason.decode!(content)}

      {:error, _reason} ->
        {:error, :not_found}
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
  # Prompt Wrapping
  # ============================================================================

  defp wrap_prompt(heading, prompt) do
    """
    # #{heading}

    #{prompt}
    """
  end

  # ============================================================================
  # Project Sync
  # ============================================================================

  defp maybe_sync_project(scope, working_dir, opts) do
    if Keyword.get(opts, :skip_sync, false) do
      {:ok, :skipped}
    else
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
