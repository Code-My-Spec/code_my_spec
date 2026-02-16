defmodule CodeMySpec.AgentTasks.ManageImplementation do
  @moduledoc """
  Master agent task that orchestrates the full implementation lifecycle of a project.

  Provides the master prompt that drives the agent through an iterative loop:

  1. Write BDD specs for the next incomplete story (via `/write-bdd-specs`)
  2. Develop the component to make failing BDD specs pass:
     - Backend contexts via `/develop-context`
     - LiveView components via `/develop-liveview`
  3. Repeat until all stories are complete and all specs pass
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectSync.Sync

  require Logger

  defp session_dir(external_id), do: ".code_my_spec/internal/sessions/#{external_id}"

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, session, opts \\ []) do
    env = scope.environment
    working_dir = get_working_dir(env)
    external_id = get_external_id(session)

    with {:ok, _sync_result} <- maybe_sync_project(scope, working_dir, opts) do
      prompt_path = "#{session_dir(external_id)}/master_prompt.md"

      unless Environments.file_exists?(env, prompt_path) do
        :ok = Environments.write_file(env, prompt_path, build_master_prompt())
      end

      next_action = assess_current_state(env, scope)
      {:ok, orchestration_message(prompt_path, next_action)}
    end
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    with {:ok, failures, exit_code} <- run_bdd_specs(env) do
      if exit_code != 0 or failures != [] do
        {:ok, :invalid, format_failure_feedback(failures)}
      else
        case BddSpecs.get_next_incomplete_story(env, scope) do
          %{} = _story ->
            {:ok, :invalid, next_story_prompt()}

          nil ->
            {:ok, :valid}
        end
      end
    end
  rescue
    exception ->
      Logger.error("[ManageImplementation] Error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  # Private functions

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

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp assess_current_state(env, scope) do
    case run_bdd_specs(env) do
      {:ok, failures, exit_code} when exit_code != 0 or failures != [] ->
        {:failing_specs, failures}

      {:ok, _failures, _exit_code} ->
        case BddSpecs.get_next_incomplete_story(env, scope) do
          %{} = _story -> :next_story
          nil -> :all_complete
        end

      {:error, _reason} ->
        :next_story
    end
  end

  defp orchestration_message(prompt_path, next_action) do
    """
    Your orchestration instructions have been written to:

    `#{prompt_path}`

    Read this file to understand your role and begin the implementation lifecycle.

    #{next_action_instruction(next_action)}
    """
  end

  defp next_action_instruction({:failing_specs, failures}) do
    failure_details =
      Enum.map_join(failures, "\n", fn f -> "- #{f.spex}: #{f.scenario}" end)

    """
    ## Immediate Action Required

    There are **failing BDD specs** that need implementation work. Do NOT write more specs.
    Check `docs/architecture/dependency_graph.mmd` and `docs/status/` to determine the
    component type and what still needs work, then invoke the appropriate command:
    - `/develop-context` for backend contexts
    - `/develop-liveview <ModuleName>` for LiveView components

    Failing specs:
    #{failure_details}
    """
  end

  defp next_action_instruction(:next_story) do
    """
    ## Immediate Action Required

    All current BDD specs pass (or none exist yet). There are incomplete stories remaining.
    Invoke `/write-bdd-specs` to generate specs for the next story.
    """
  end

  defp next_action_instruction(:all_complete) do
    """
    ## Status: Complete

    All stories are complete and all BDD specs pass. No further action needed.
    """
  end

  defp build_master_prompt do
    """
    # Implementation Management — Orchestrator Role

    You are the **orchestrator** for this project's implementation lifecycle. Your primary
    job is to delegate work to sub-agents via slash commands and evaluate their results.

    ## Critical Rule: Preserve Your Context Window

    Your context window is a finite, precious resource. Every token you spend reading files,
    analyzing code, or reasoning about implementation details is a token you cannot spend
    on orchestration. You must:

    - **Never** write source files, test files, or spec files yourself.
    - **Never** analyze implementation details, debug failures, or reason about fixes.
    - **Always** delegate all substantive work to sub-agents via the slash commands below.

    Your role is to invoke the right command at the right time and let the sub-agent
    handle all the details.

    ## Orchestration Loop

    Follow this cycle:

    1. **`/write-bdd-specs`** — Delegates to a sub-agent that generates BDD specifications
       for the next incomplete user story. These become failing tests that define "done".
    2. **Implement** — Decide what to develop next by consulting:
       - `docs/architecture/dependency_graph.mmd` — Shows all components, their types,
         and dependency relationships
       - `docs/status/` — Shows implementation progress for each component (what's done
         and what still needs work)

       Then choose the right command:
       - **`/develop-context`** — For backend context components (type: `context`,
         `coordination_context`). Develops the context and makes failing BDD specs pass.
       - **`/develop-liveview <ModuleName>`** — For LiveView components (type: `liveview`,
         `liveview_component`). Orchestrates the full LiveView lifecycle: specification,
         child component specs, and implementation in dependency order.
    3. **Repeat** — The evaluate hook will tell you whether specs pass or if more stories
       remain. Follow its guidance. Do not run tests or inspect results yourself.

    ## Architecture & Status Reference

    - `docs/architecture/dependency_graph.mmd` — Component dependency graph with types
    - `docs/architecture/overview.md` — Component catalog with descriptions and dependencies
    - `docs/architecture/namespace_hierarchy.md` — Module namespace tree
    - `docs/status/` — Per-component implementation status (specs, tests, code)

    ## What You Should NOT Do

    - Do not attempt to fix issues yourself — delegate back to the appropriate sub-agent.

    ## When to Stop

    The evaluate hook will signal completion when all stories are done and all specs pass.
    Trust the hook.
    """
  end

  defp run_bdd_specs(env) do
    spec_files = CodeMySpec.Environments.glob(env, "test/spex/**/*_spex.exs")

    if Enum.empty?(spec_files) do
      {:ok, [], 0}
    else
      BddSpecs.run_specs(spec_files, project_root: env.cwd, quiet: true)
    end
  end

  defp format_failure_feedback(failures) do
    failure_details =
      Enum.map_join(failures, "\n", fn f -> "- #{f.spex}: #{f.scenario}" end)

    """
    BDD specs are failing. The specs define the correct behavior — you need to
    implement the component to make them pass.

    Failing specs:
    #{failure_details}

    Check `docs/architecture/dependency_graph.mmd` and `docs/status/` to determine the
    component type and what still needs work, then invoke:
    - `/develop-context` for backend contexts
    - `/develop-liveview <ModuleName>` for LiveView components
    """
  end

  defp next_story_prompt do
    """
    All current BDD specs pass, but there are incomplete stories remaining.
    Invoke `/write-bdd-specs` to generate specs for the next story.
    """
  end
end
