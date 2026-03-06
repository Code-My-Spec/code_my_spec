defmodule CodeMySpec.AgentTasks.StartImplementation do
  @moduledoc """
  Graph-driven orchestrator that uses NextActionable + Dispatch to find and
  execute the next actionable requirement for a project.

  ## Flow

  ### command/3
  1. `get_next_actions` → walks project → stories → components → dependencies
  2. `Dispatch.command` → generates prompt (handles :local and :children scope)
  3. Write status file for tracking, return prompt

  Caller (`StartAgentTask`) is responsible for syncing before calling command.

  ### evaluate/3
  1. Sync project (requirements refreshed after agent work)
  2. Re-walk the graph via `dispatch_or_complete`
  3. If unsatisfied requirement found → return prompt as feedback
  4. If all complete → return :valid

  The status file is for observability only — evaluate does not depend on it.
  """

  require Logger

  alias CodeMySpec.{Environments, FrameworkSync}
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.ProjectCoordinator.Dispatch
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Requirements.Requirement

  @status_path CodeMySpec.Paths.implementation_status_path()

  # ============================================================================
  # Public API
  # ============================================================================

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, _session, _opts \\ []) do
    sync_framework(scope.environment)
    dispatch(scope.environment, scope)
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _session, _opts \\ []) do
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
            write_status(env, req)
            {:ok, prompt}

          {:error, reason} ->
            {:error, reason}
        end

      :complete ->
        Logger.info("[StartImplementation] All requirements complete")
        clear_status(env)
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
            write_status(env, req)
            {:ok, :invalid, prompt}

          {:error, reason} ->
            {:error, reason}
        end

      :complete ->
        Logger.info("[StartImplementation] All requirements complete")
        clear_status(env)
        {:ok, :valid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Status File I/O (tracking/observability only)
  # ============================================================================

  defp write_status(env, %Requirement{} = req) do
    data = %{
      requirement: req.name,
      scope: req.scope,
      component_id: req.component_id,
      story_id: req.story_id,
      project_id: req.project_id,
      dispatched_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ok = Environments.write_file(env, @status_path, Jason.encode!(data))
  end

  defp clear_status(env) do
    Environments.delete_file(env, @status_path)
    :ok
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
    Logger.info("[StartImplementation] Syncing project from #{working_dir}")

    case Sync.sync_all(scope, base_dir: working_dir) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:sync_failed, reason}}
    end
  end

  defp get_working_dir(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp get_working_dir(%{ref: %{working_dir: dir}}), do: dir
  defp get_working_dir(_), do: File.cwd!()
end
