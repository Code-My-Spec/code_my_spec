defmodule CodeMySpec.McpServers.Tasks.Tools.CancelTask do
  @moduledoc """
  Cancel a task on the current session (Story 704 / Rule 4).

  Transitions the task to `:cancelled` without going through
  `evaluate_task`. Used to unstick the loop when a task can't make
  progress and the agent wants to move on. No PermissionSocket
  involvement — routine admin owned by the agent.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"

    field :task_id, :string, required: true, doc: "Task to cancel"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    task_id = Map.get(params, :task_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id),
         {:ok, _task} <- ensure_task(session, task_id),
         {:ok, _updated} <- Sessions.complete_task(scope, session, task_id, :cancelled) do
      msg = "Task `#{task_id}` cancelled."
      {:reply, Response.tool() |> Response.text(msg), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end

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
    case Session.find_task(session, task_id) do
      nil -> {:error, "Task not found: #{task_id}"}
      task -> {:ok, task}
    end
  end
end
