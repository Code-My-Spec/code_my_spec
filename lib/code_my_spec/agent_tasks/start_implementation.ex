defmodule CodeMySpec.AgentTasks.StartImplementation do
  @moduledoc """
  Graph-driven orchestrator that uses NextActionable + Dispatch to find and
  execute the next actionable requirement for a project.

  ## Flow

  ### command/3
  1. `get_next_actions` → walks project → stories → components → dependencies
  2. `Dispatch.command` → generates prompt (handles :local and :children scope)
  3. Write status (the dispatched requirement ID), return prompt

  Caller (`StartAgentTask`) is responsible for syncing before calling command.

  ### evaluate/3
  1. Read status → reload requirement
  2. Sync project (requirements may have changed after agent work)
  3. `Dispatch.evaluate` → check if the dispatched work is complete
  4. If valid → clear status → sync again → re-dispatch (next requirement)
  5. If invalid → return feedback
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.ProjectCoordinator.Dispatch
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Requirement

  @status_path CodeMySpec.Paths.implementation_status_path()

  # ============================================================================
  # Public API
  # ============================================================================

  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, _session, _opts \\ []) do
    dispatch(scope.environment, scope)
  end

  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _session, _opts \\ []) do
    env = scope.environment

    with {:ok, req} <- load_dispatched_requirement(env),
         {:ok, _} <- sync_project(scope),
         {:ok, :valid} <- evaluate_requirement(req, scope),
         :ok <- clear_status(env),
         {:ok, _} <- sync_project(scope) do
      # Current task valid — re-sync and dispatch next
      dispatch_or_complete(env, scope)
    else
      {:ok, :invalid, feedback} ->
        {:ok, :invalid, feedback}

      {:error, :not_found} ->
        Logger.info("[StartImplementation] Evaluate: no active task")
        {:ok, :valid}

      {:error, reason} ->
        {:error, reason}
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
  # Evaluate the dispatched requirement
  # ============================================================================

  defp evaluate_requirement(req, scope) do
    Dispatch.evaluate(req, scope, %{})
  end

  # ============================================================================
  # Status File I/O
  # ============================================================================

  defp write_status(env, %Requirement{} = req) do
    data = %{requirement_id: req.id}
    :ok = Environments.write_file(env, @status_path, Jason.encode!(data))
  end

  defp load_dispatched_requirement(env) do
    case Environments.read_file(env, @status_path) do
      {:ok, content} ->
        %{"requirement_id" => req_id} = Jason.decode!(content)
        req = Repo.get!(Requirement, req_id)
        {:ok, req}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp clear_status(env) do
    Environments.delete_file(env, @status_path)
    :ok
  end

  # ============================================================================
  # Sync
  # ============================================================================

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
