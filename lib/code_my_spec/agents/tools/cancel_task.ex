defmodule CodeMySpec.Agents.Tools.CancelTask do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Sessions
  alias CodeMySpec.TaskOwner

  @impl true
  def name, do: "cancel_task"

  @impl true
  def description do
    """
    Cancel a task on the current session (Story 704 / Rule 4).

    Transitions the task to `:cancelled` without going through
    `evaluate_task`. Used to unstick the loop when a task can't make
    progress and the agent wants to move on. No PermissionSocket
    involvement — routine admin owned by the agent.
    """
  end

  @impl true
  def params do
    %{
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]},
      task_id: {:required, {:meta, :string, [description: "Task to cancel"]}}
    }
  end

  @impl true
  def call(params, context) do
    session_id = Map.get(params, :session_id)
    task_id = Map.get(params, :task_id)

    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, owner} <- resolve_owner(scope, context[:agent_id], session_id),
         {:ok, _task} <- ensure_task(owner, task_id),
         {:ok, _updated} <- TaskOwner.complete_task(scope, owner, task_id, :cancelled) do
      msg = "Task `#{task_id}` cancelled."
      {:ok, msg}
    else
      {:error, reason} ->
        {:error, "#{reason}"}
    end
  end

  defp resolve_owner(scope, agent_id, _session_id) when is_binary(agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, _} -> {:error, "Agent not found in this project"}
    end
  end

  defp resolve_owner(scope, _agent_id, session_id), do: resolve_session(scope, session_id)

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _),
    do:
      {:error,
       "No session_id and no agent id on this call, so there is nothing to act on.\n\n" <>
         "If you are Claude Code: `register_session` with this conversation's id " <>
         "(CLAUDE_SESSION_ID) creates it on this server.\n\n" <>
         "If you are an agent we run: your id travels on the connection and you " <>
         "cannot supply it — this is a harness fault, not something to retry or " <>
         "ask a person about. Report it with `create_issue` and carry on."}

  defp ensure_task(session, task_id) do
    case TaskOwner.find_task(session, task_id) do
      nil ->
        {:error, "Task not found: #{task_id}"}

      %{status: status} when status in [:completed, :cancelled] ->
        {:error, "Task is already finished: #{task_id}"}

      task ->
        {:ok, task}
    end
  end
end
