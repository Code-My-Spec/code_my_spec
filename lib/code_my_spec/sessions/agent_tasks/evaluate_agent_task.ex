defmodule CodeMySpec.Sessions.AgentTasks.EvaluateAgentTask do
  @moduledoc """
  Evaluate/validate an agent task session's output.

  Looks up the session by ID, determines its type, and calls the appropriate
  AgentTask module's evaluate/3 function to validate Claude's output.

  ## Usage

  Typically called by the Stop hook after an agent task session completes.

  ## Output

  Returns a map for hook decision control:
  - If valid: `%{}` (empty map allows Claude to stop), marks session complete
  - If invalid: `%{"decision" => "block", "reason" => "<feedback>"}` (blocks Claude from stopping)
  - If error: `%{}` (allows Claude to stop), error logged
  """

  require Logger

  alias CodeMySpec.Sessions
  alias CodeMySpec.ProjectSync.Sync

  @doc """
  Run evaluation and return the result map for hook output.
  Does not perform any IO - caller is responsible for output.
  """
  @spec run(CodeMySpec.Scope.t(), map()) :: map()
  def run(scope, args) do
    session_id_arg = Map.get(args, :session_id)
    working_dir = Map.get(args, :working_dir)

    with {:ok, session_id} when not is_nil(session_id) <- resolve_session_id(session_id_arg),
         {:ok, session} <- get_session(scope, session_id),
         :ok <- check_session_active(session),
         {:ok, task_session} <- build_task_session(session, working_dir),
         {:ok, sync_result} <- sync_project(scope, working_dir),
         result <- session.type.evaluate(scope, task_session) do
      log_sync_metrics(sync_result)
      maybe_complete_session(scope, session, result)
      format_result(result)
    else
      {:ok, nil} ->
        format_result({:ok, nil})

      {:ok, {:already_closed, status}} ->
        Logger.info("[EvaluateAgentTask] Session already #{status}, skipping evaluation")
        %{}

      {:error, reason} ->
        format_setup_error(reason)
    end
  rescue
    error ->
      Logger.error("[EvaluateAgentTask] Error: #{Exception.message(error)}")
      %{}
  end

  defp resolve_session_id(nil), do: {:ok, nil}
  defp resolve_session_id(id) when is_binary(id), do: {:ok, id}

  defp get_session(scope, session_id) do
    case Sessions.get_session(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp check_session_active(%{status: :active}), do: :ok
  defp check_session_active(%{status: status}), do: {:ok, {:already_closed, status}}

  defp maybe_complete_session(scope, session, {:ok, :valid}) do
    Sessions.update_session(scope, session, %{status: :complete})
  end

  defp maybe_complete_session(_scope, _session, _result), do: :ok

  defp build_task_session(session, working_dir) do
    # Session should have component and project preloaded
    {:ok,
     %{
       external_id: session.external_conversation_id,
       component: session.component,
       project: session.project,
       environment_type: session.environment_type,
       working_dir: working_dir
     }}
  end

  defp format_result({:ok, nil}), do: %{}

  defp format_result({:ok, :valid}) do
    Logger.info("[EvaluateAgentTask] All checks passed!")
    %{}
  end

  defp format_result({:ok, :invalid, feedback}) do
    %{"decision" => "block", "reason" => feedback}
  end

  defp format_result({:error, reason}) do
    Logger.error("[EvaluateAgentTask] Error: #{format_error(reason)}")
    %{}
  end

  defp format_setup_error(reason) do
    Logger.error("[EvaluateAgentTask] Setup error: #{format_error(reason)}")
    %{"decision" => "block", "reason" => format_error(reason)}
  end

  defp sync_project(scope, working_dir) do
    opts = if working_dir, do: [base_dir: working_dir], else: []

    case Sync.sync_all(scope, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, "Sync failed: #{inspect(reason)}"}
    end
  end

  defp log_sync_metrics(%{timings: timings}) do
    Logger.info(
      "[EvaluateAgentTask] Sync: contexts=#{timings.contexts_sync_ms}ms requirements=#{timings.requirements_sync_ms}ms total=#{timings.total_ms}ms"
    )
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_error(reason), do: inspect(reason)
end
