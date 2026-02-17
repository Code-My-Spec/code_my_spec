defmodule CodeMySpec.AgentTasks.ManageImplementation do
  @moduledoc """
  State machine that orchestrates the full implementation lifecycle of a project.

  Instead of generating a master prompt and asking the LLM to reason about
  component ordering and slash commands, this module directly delegates to
  WriteBddSpecs, DevelopContext, and DevelopLiveView, tracks the current task
  via a status file, and returns delegated prompts directly.

  The orchestration decision is driven by BDD spec results:

    1. Run BDD specs
    2. If specs are failing → develop the next prioritized context/liveview
    3. If specs are passing → write BDD specs for the next incomplete story
    4. If all specs pass and no stories remain → done

  This creates an interleaved loop: write specs for one story, develop until
  those specs pass, then write specs for the next story.

  State transitions:

    command/3 (session start):
      sync → run BDD specs → decide next task → delegate → write status → return prompt

    evaluate/3 (stop hook):
      read status → evaluate delegated task
      → invalid? → pass through feedback (keep working)
      → valid?  → run BDD specs → decide next task → delegate or complete
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Stories

  alias CodeMySpec.AgentTasks.{DevelopContext, DevelopLiveView, WriteBddSpecs}

  require Logger

  @status_path "docs/status/implementation_status.json"

  @developable_types ["context", "coordination_context", "liveview", "liveview_component"]

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
  # Orchestration Decision (BDD-spec driven)
  # ============================================================================

  defp decide_next_task(env, scope) do
    case run_bdd_specs(env) do
      {:ok, failures, exit_code} when exit_code != 0 or failures != [] ->
        decide_on_failing_specs(scope, failures)

      {:ok, _failures, _exit_code} ->
        decide_on_passing_specs(env, scope)

      {:error, _reason} ->
        decide_on_passing_specs(env, scope)
    end
  end

  defp decide_on_failing_specs(scope, failures) do
    case find_next_component(scope) do
      {component, task_module} -> {:develop, component, task_module}
      nil -> {:specs_failing_no_target, failures}
    end
  end

  defp decide_on_passing_specs(env, scope) do
    case BddSpecs.get_next_incomplete_story(env, scope) do
      %{} = story -> {:write_bdd_specs, story}
      nil -> :all_complete
    end
  end

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

      {:develop, component, task_module} ->
        dev_session = %{component: component, project: scope.active_project}
        {:ok, prompt} = task_module.command(scope, dev_session)

        write_status(env, %{
          task: task_key(task_module),
          module_name: component.module_name,
          component_id: component.id
        })

        {:ok, wrap_prompt("Develop: #{component.name}", prompt)}

      {:specs_failing_no_target, failures} ->
        clear_status(env)
        {:ok, wrap_prompt("BDD Specs Failing", format_failure_details(failures))}

      :all_complete ->
        clear_status(env)

        {:ok,
         "All stories are complete and all components are implemented. No further action needed."}
    end
  end

  # ============================================================================
  # Component Finding (context/liveview level only)
  # ============================================================================

  defp find_next_component(scope) do
    ready_components =
      Components.components_with_unsatisfied_requirements(scope)
      |> Enum.filter(fn c -> c.type in @developable_types and dependencies_satisfied?(c) end)

    stories = Stories.list_project_stories_by_priority(scope)

    # Build component_id → min_priority map from stories
    priority_map =
      Enum.reduce(stories, %{}, fn story, acc ->
        if story.component_id,
          do: Map.put_new(acc, story.component_id, story.priority),
          else: acc
      end)

    ready_components
    |> Enum.sort_by(fn c ->
      {Map.get(priority_map, c.id, :infinity), c.name}
    end)
    |> List.first()
    |> case do
      nil -> nil
      component -> {component, task_module_for_component(component)}
    end
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
  # Task Module Mapping
  # ============================================================================

  defp task_module_for_component(%{type: type})
       when type in ["context", "coordination_context"],
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

  defp dispatch_advance(env, scope, _session, {:develop, component, task_module}) do
    dev_session = %{component: component, project: scope.active_project}
    {:ok, prompt} = task_module.command(scope, dev_session)

    write_status(env, %{
      task: task_key(task_module),
      module_name: component.module_name,
      component_id: component.id
    })

    wrap_prompt("Develop: #{component.name}", prompt)
  end

  defp dispatch_advance(env, _scope, _session, {:specs_failing_no_target, failures}) do
    clear_status(env)
    wrap_prompt("BDD Specs Failing", format_failure_details(failures))
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
    BDD specs are failing but no context or LiveView component is ready for development.
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
