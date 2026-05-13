defmodule CodeMySpec.McpServers.Tasks.Tools.AssignSubagent do
  @moduledoc """
  Assign a registered sub-agent to an open task (Story 704 / Rule 4).

  Atomically updates `Task.agent_id`: if the sub-agent currently owns a
  different task on this session, that task's `agent_id` is cleared and
  the target task's `agent_id` is set in the **same** `Repo.update` —
  no partial-failure window where the sub-agent ends up unassigned
  from their old task while not landing on the new one.

  Errors when:
  - the `agent_id` is not currently active in `session.subagents`
    (filtered through `Session.active_subagents/2`, so TTL-expired
    registrations are rejected the same way a fully unknown id is)
  - the `task_id` is not on the session
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :session_id, :string,
      doc: "Injected by hook — do not set manually"

    field :agent_id, :string, required: true, doc: "Registered sub-agent id"

    field :task_id, :string, required: true, doc: "Target task id"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    agent_id = Map.get(params, :agent_id)
    task_id = Map.get(params, :task_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id),
         :ok <- ensure_active(scope, session, agent_id),
         {:ok, target} <- ensure_task(session, task_id),
         {:ok, _updated} <- Sessions.reassign_agent(scope, session, task_id, agent_id) do
      msg =
        "Assigned sub-agent `#{agent_id}` to task `#{task_id}` " <>
          "(#{target.requirement_name || "—"})."

      {:reply, Response.tool() |> Response.text(msg), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{format_reason(reason)}"), frame}
    end
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _), do: {:error, "No session_id available"}

  defp ensure_active(scope, session, agent_id) do
    ttl = Configurations.get_or_create(scope).subagent_ttl_minutes

    if Enum.any?(Session.active_subagents(session, ttl), &(&1.agent_id == agent_id)) do
      :ok
    else
      {:error,
       "agent_id `#{agent_id}` is not an active registered sub-agent on this session"}
    end
  end

  defp ensure_task(session, task_id) do
    case Session.find_task(session, task_id) do
      nil -> {:error, "Task not found: #{task_id}"}
      task -> {:ok, task}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
