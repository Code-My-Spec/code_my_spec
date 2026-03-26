defmodule CodeMySpec.AgentTasks.StartImplementation do
  @moduledoc """
  Graph-driven orchestrator that uses NextActionable + Dispatch to find and
  execute the next actionable requirement for a project.

  ## Flow

  ### command/3
  1. Sync framework files
  2. `get_next_actions` → walks project → stories → components → dependencies
  3. `Dispatch.command` → generates prompt (handles :local, :orchestrate, :children scope)
  4. Return prompt (Dispatch records task entries with prompt_path for matching)

  Caller (`StartAgentTask`) is responsible for syncing before calling command.

  ### evaluate/3
  1. Sync project (requirements refreshed after agent work)
  2. Re-walk the graph via `dispatch_or_complete`
  3. If unsatisfied requirement found → return prompt as feedback
  4. If all complete → return :valid
  """

  require Logger

  alias CodeMySpec.FrameworkSync
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.ProjectCoordinator.{Dispatch, ImplementationStatus}
  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Requirements.Requirement

  # ============================================================================
  # Public API
  # ============================================================================

  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, _task) do
    sync_framework(scope.environment)
    dispatch(scope.environment, scope)
  end

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _task) do
    env = scope.environment

    with {:ok, _} <- sync_project(scope) do
      dispatch_or_complete(env, scope)
    end
  rescue
    exception ->
      Logger.error("[StartImplementation] Error: #{Exception.message(exception)}")
      {:error, {:execution_error, Exception.message(exception)}}
  end

  # ============================================================================
  # Core: dispatch via graph
  # ============================================================================

  defp dispatch(env, scope) do
    case ProjectCoordinator.get_next_actions(scope) do
      {:ok, %Requirement{} = req} ->
        Logger.info("[StartImplementation] Dispatching: #{req.name} (scope: #{req.scope})")

        case Dispatch.command(req, scope, %{}) do
          {:ok, prompt} ->
            {:ok, prompt}

          {:error, reason} ->
            {:error, reason}
        end

      :complete ->
        Logger.info("[StartImplementation] All requirements complete")
        ImplementationStatus.clear(env)
        {:ok, "All requirements are satisfied. No further action needed."}

      {:error, reason} ->
        Logger.warning("[StartImplementation] Graph error: #{reason}")
        {:error, reason}
    end
  end

  defp dispatch_or_complete(env, scope) do
    case ProjectCoordinator.get_next_actions(scope) do
      {:ok, %Requirement{} = req} ->
        Logger.info("[StartImplementation] Next: #{req.name} (scope: #{req.scope})")

        case Dispatch.command(req, scope, %{}) do
          {:ok, prompt} ->
            {:ok, :invalid, prompt}

          {:error, reason} ->
            {:error, reason}
        end

      :complete ->
        Logger.info("[StartImplementation] All requirements complete")
        ImplementationStatus.clear(env)
        {:ok, :valid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Sync
  # ============================================================================

  defp sync_framework(env) do
    cwd = get_working_dir(env)
    FrameworkSync.sync(cwd)
  end

  defp sync_project(scope) do
    working_dir = get_working_dir(scope.environment)
    Logger.info("[StartImplementation] Incremental sync from #{working_dir}")

    case ProjectSync.incremental_sync(scope, base_dir: working_dir) do
      {:ok, _result} -> {:ok, :synced}
      {:error, reason} -> {:error, {:sync_failed, reason}}
    end
  end

  defp get_working_dir(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp get_working_dir(%{ref: %{working_dir: dir}}), do: dir
  defp get_working_dir(_), do: File.cwd!()
end
