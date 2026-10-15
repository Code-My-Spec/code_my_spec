defmodule CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents do
  @moduledoc """
  List all registered sub-agents on the current session, filtered by
  the configured TTL (Story 704 / Rule 3).

  Returns each sub-agent's identity, when they registered, and their
  assignment status — idle (no Task in this session carries their
  agent_id) or the task they own (via Task.agent_id match).

  TTL-expired registrations are filtered out (lazy prune from Rule 2);
  callers see the same truth the engineer's session detail page renders.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  schema do
    field :session_id, :string, description: "Injected by hook — do not set manually"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id) do
      ttl = Configurations.get_or_create(scope).subagent_ttl_minutes
      active = Session.active_subagents(session, ttl)

      response = Response.tool() |> Response.text(format(active, session))
      {:reply, response, frame}
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

  # An agent we run supplies no session_id -- its identity travels on the
  # connection as the working copy's own harness, not a Claude-assigned
  # session id (issue 69808362). `Sessions.external_id_for_harness/1` is the
  # same newest-session-wins join already used by list_user_questions,
  # ask_user_question and check_answer to answer exactly this: which
  # conversation is running in the working copy already on scope.
  defp resolve_session(%Scope{active_working_copy_id: working_copy_id} = scope, _)
       when is_binary(working_copy_id) do
    case Sessions.external_id_for_harness(working_copy_id) do
      nil -> no_session_error()
      external_id -> resolve_session(scope, external_id)
    end
  end

  defp resolve_session(_scope, _), do: no_session_error()

  defp no_session_error,
    do:
      {:error,
       "No session is registered for this working copy, so there are no sub-agents to " <>
         "list.\n\n" <>
         "If you are Claude Code: `register_session` with this conversation's id " <>
         "(CLAUDE_SESSION_ID) creates it on this server."}

  defp format([], _session), do: "No registered sub-agents on this session."

  defp format(subagents, session) do
    header = "# Registered Sub-agents (#{length(subagents)})\n\n"
    rows = Enum.map_join(subagents, "\n", &row(&1, session))
    header <> rows
  end

  defp row(subagent, session) do
    assignment = assignment_for(session, subagent.agent_id)
    name = subagent.agent_name || subagent.agent_id

    "- **#{name}** `agent_id=#{subagent.agent_id}` " <>
      "registered=#{format_dt(subagent.last_heartbeat_at)} — #{assignment}"
  end

  defp assignment_for(session, agent_id) do
    case Session.find_task_by_agent(session, agent_id) do
      nil ->
        "idle"

      task ->
        "assigned to task `#{task.id}` (#{task.requirement_name || "—"})"
    end
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end
