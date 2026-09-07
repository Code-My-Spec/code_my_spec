defmodule CodeMySpec.McpServers.Tasks.Tools.ListTasks do
  @moduledoc """
  List all tasks on the current session.

  Returns task status, agent assignment, component, and requirement
  so the main agent can track subagent progress.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"

    field :status, :string,
      doc: "Filter by status: active, completed, failed, cancelled (optional)"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    status_filter = Map.get(params, :status)

    with {:ok, status} <- parse_status(status_filter),
         {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, owner} <- resolve_owner(scope, session_id, frame.assigns[:agent_id]) do
      tasks = filter_tasks(owner.tasks || [], status)
      response = Response.tool() |> Response.text(format_tasks(tasks))
      {:reply, response, frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end

  defp filter_tasks(tasks, nil), do: tasks
  defp filter_tasks(tasks, status), do: Enum.filter(tasks, &(&1.status == status))

  defp format_tasks([]), do: "No tasks on this session."

  defp format_tasks(tasks) do
    header = "# Session Tasks (#{length(tasks)})\n\n"
    rows = Enum.map_join(tasks, "\n", &format_task_row/1)
    header <> rows
  end

  defp format_task_row(task) do
    icon = status_icon(task.status)
    agent = if task.agent_id, do: "agent=#{task.agent_id}", else: "unassigned"
    component = task.component_module_name || "—"

    "- #{icon} **#{task.requirement_name}** #{component} [#{task.status}] #{agent} `#{task.id}`"
  end

  defp status_icon(:completed), do: "✓"
  defp status_icon(:active), do: "●"
  defp status_icon(:failed), do: "✗"
  defp status_icon(:cancelled), do: "—"
  defp status_icon(:prepared), do: "○"
  defp status_icon(_), do: "?"

  # An agent we run owns its tasks directly, so it is the owner and there is no
  # session in the picture. Ahead of the session clause for the same reason as
  # in `evaluate_task`: a call carrying both is one of ours.
  #
  # This clause did not exist, and the cost was watched on 2026-09-07. The
  # war-epic coding agent called `list_tasks`, was told "call `register_session`
  # with this conversation's id", looked `register_session` up, found it is not
  # a tool it carries — and then asked *John* to register the conversation or
  # hand it a session id. A question he could not usefully answer, about a
  # session that should never have been wanted, while seven completed tasks sat
  # on its own row.
  defp resolve_owner(scope, _session_id, agent_id) when is_binary(agent_id) do
    Agents.fetch_agent(scope, agent_id)
  end

  defp resolve_owner(scope, session_id, _agent_id), do: resolve_session(scope, session_id)

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  # Neither identity arrived, so there is no owner whose tasks these would be.
  #
  # `register_session` is named only to the caller that can follow it. It is a
  # Claude Code tool and no coding agent carries one — being told to call it is
  # what sent an agent to ask a person for a session id.
  defp resolve_session(_scope, _),
    do:
      {:error,
       "No session_id and no agent id on this call, so there is no owner whose " <>
         "tasks to list.\n\n" <>
         "If you are Claude Code: `register_session` with this conversation's id " <>
         "(CLAUDE_SESSION_ID) creates it on this server.\n\n" <>
         "If you are an agent we run: your id travels on the connection and you " <>
         "cannot supply it — this is a harness fault, not something to retry or " <>
         "ask a person about. Report it with `create_issue` and carry on."}

  @valid_statuses ~w(prepared active completed failed cancelled)

  defp parse_status(nil), do: {:ok, nil}

  defp parse_status(s) when is_binary(s) do
    if s in @valid_statuses do
      {:ok, String.to_existing_atom(s)}
    else
      {:error, "Invalid status: #{inspect(s)}. Allowed: #{Enum.join(@valid_statuses, ", ")}."}
    end
  end
end
