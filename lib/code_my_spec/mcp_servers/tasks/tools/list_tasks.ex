defmodule CodeMySpec.McpServers.Tasks.Tools.ListTasks do
  @moduledoc """
  List tasks — your own, or a named agent's.

  Returns task status, agent assignment, component, and requirement
  so the main agent can track subagent progress.

  Pass `agent_id` to read that agent's queue instead of your own. Without it
  this answers about the caller, which is what every agent means when it asks
  what it is holding.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"

    field :agent_id, :string,
      doc: "Whose tasks to list. Omit for your own; name an agent to read its queue."

    field :status, :string,
      doc: "Filter by status: active, completed, failed, cancelled (optional)"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    status_filter = Map.get(params, :status)

    # An explicit `agent_id` wins over the caller's own identity, and that is the
    # whole of supervising: `resolve_owner/3` read only `frame.assigns`, so this
    # answered about whoever called it and there was no way to ask about anyone
    # else. The moduledoc has always said "so the main agent can track subagent
    # progress" — it could not.
    #
    # Measured before the change: a QA agent's stop menu told it "you have 4 open
    # tasks ... call `evaluate_task` with task_id 6735cdc7", while the main agent
    # calling this tool got its own session's 277 and no `6735cdc7` among them.
    # Supervisor and supervised disagreed about which tasks existed and neither
    # could see the other's view, so "idle because finished" and "idle holding
    # four unevaluated tasks" were indistinguishable from the outside.
    #
    # `Agents.fetch_agent/2` is scope-guarded, so this reaches only agents on the
    # caller's own project — naming somebody else's agent finds nothing rather
    # than crossing a boundary.
    agent_id = Map.get(params, :agent_id) || frame.assigns[:agent_id]

    with {:ok, status} <- parse_status(status_filter),
         {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, owner} <- resolve_owner(scope, session_id, agent_id) do
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

  defp format_tasks([]), do: "No tasks."

  defp format_tasks(tasks) do
    # Not "Session Tasks" any more: with an `agent_id` these are an agent's,
    # and a header naming the wrong owner is how the two views got confused in
    # the first place. The rows carry the assignment.
    header = "# Tasks (#{length(tasks)})\n\n"
    rows = Enum.map_join(tasks, "\n", &format_task_row/1)
    header <> rows
  end

  defp format_task_row(task) do
    icon = status_icon(task.status)
    agent = if task.agent_id, do: "agent=#{task.agent_id}", else: "unassigned"
    component = task.component_module_name || "—"

    "- #{icon} **#{task.requirement_name}** #{component} [#{task.status}] #{agent} `#{task.id}`" <>
      blocker(task)
  end

  # What a blocked task is waiting on, and whether it still is.
  #
  # `[blocked]` alone says neither, and both are things the agent has to know
  # without reading the database. Criterion 3223 reads the question id off this
  # row after an explicit restart — the agent comes back with nothing in memory
  # and this listing is where the link between the task and the question it
  # asked survives. Criterion 2419 is the other half: an agent holding two
  # blocked attempts has to tell the one that has been answered from the one
  # still waiting, and picking the wrong one is a `start_task` that gets
  # refused for no visible reason.
  defp blocker(%{status: :blocked, blocker_type: type} = task) when not is_nil(type) do
    " — blocked on #{type} `#{task.blocker_id}` #{waiting_or_resolved(task)}"
  end

  defp blocker(_task), do: ""

  defp waiting_or_resolved(%{blocker_resolved_at: nil}), do: "(waiting)"
  defp waiting_or_resolved(_task), do: "(resolved — resume it with start_task)"

  defp status_icon(:completed), do: "✓"
  defp status_icon(:active), do: "●"
  defp status_icon(:failed), do: "✗"
  defp status_icon(:cancelled), do: "—"
  defp status_icon(:prepared), do: "○"
  defp status_icon(:blocked), do: "⏸"
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
  #
  # The Claude Code half used to stop at "call `register_session`", and a caller
  # that did got this same refusal from the next line of the same script — so the
  # advice read as a lie and the caller went looking for a session id to pass by
  # hand. Registering creates the session; it was never what carried the id here.
  # Since `1a892606` the id travels into a script from `run_script`'s own input,
  # so the remaining case is a conversation whose SessionStart hook is not
  # injecting one at all, and the remedy for that is to say which id rather than
  # to register again.
  defp resolve_session(_scope, _),
    do:
      {:error,
       "No session_id and no agent id on this call, so there is no owner whose " <>
         "tasks to list.\n\n" <>
         "If you are Claude Code: normally the hook injects `session_id` and you " <>
         "never see this. Without it, pass the id yourself — `list_tasks({ " <>
         "session_id = \"…\" })` — and `register_session` first if this server has " <>
         "never seen the conversation. Registering alone will not fix this: it " <>
         "creates the session, it does not tell this call which one you are.\n\n" <>
         "If you are an agent we run: your id travels on the connection and you " <>
         "cannot supply it — this is a harness fault, not something to retry or " <>
         "ask a person about. Report it with `create_issue` and carry on."}

  # From the schema, not a copy of it. This list said
  # `prepared active completed failed cancelled` while the schema had been
  # writing `:blocked` for days, so filtering for the state the whole
  # durable-work model turns on answered "Invalid status".
  @valid_statuses Enum.map(CodeMySpec.Sessions.Task.statuses(), &Atom.to_string/1)

  defp parse_status(nil), do: {:ok, nil}

  defp parse_status(s) when is_binary(s) do
    if s in @valid_statuses do
      {:ok, String.to_existing_atom(s)}
    else
      {:error, "Invalid status: #{inspect(s)}. Allowed: #{Enum.join(@valid_statuses, ", ")}."}
    end
  end
end
