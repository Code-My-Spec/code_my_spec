defmodule CodeMySpec.McpServers.Tasks.Tools.AssignTask do
  @moduledoc """
  Assign an existing task to a subagent.

  The main agent uses this to claim a task on behalf of a subagent
  before spawning it. Pass the `agent_id` that the subagent will use
  so it appears on the task record immediately.

  Returns the work prompt so the main agent can forward it to the subagent.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions

  schema do
    field :task_id, :string,
      required: true,
      doc: "ID of the task to assign"

    field :agent_id, :string,
      required: true,
      doc: "Subagent identifier to assign to the task"

    field :session_id, :string, doc: "Injected by hook — do not set manually"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    task_id = Map.get(params, :task_id)
    agent_id = Map.get(params, :agent_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id),
         {:ok, task} <- find_task(session, task_id) do
      Sessions.assign_agent(scope, session, task.id, agent_id)

      text = """
      # Task Assigned

      Task `#{task_id}` assigned to agent `#{agent_id}`.

      - Component: #{task.component_module_name || "—"}
      - Requirement: #{task.requirement_name}
      """

      response = Anubis.Server.Response.tool() |> Anubis.Server.Response.text(text)
      {:reply, response, frame}
    else
      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
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

  defp find_task(session, task_id) do
    case Enum.find(session.tasks || [], &(&1.id == task_id)) do
      nil -> {:error, "Task #{task_id} not found on session"}
      task -> {:ok, task}
    end
  end
end
