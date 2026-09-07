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

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"
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

  defp resolve_session(_scope, _),
    do:
      {:error,
       "No session_id and no agent id on this call, so there is nothing to act on.\n\n" <>
         "If you are Claude Code: `register_session` with this conversation's id " <>
         "(CLAUDE_SESSION_ID) creates it on this server.\n\n" <>
         "If you are an agent we run: your id travels on the connection and you " <>
         "cannot supply it — this is a harness fault, not something to retry or " <>
         "ask a person about. Report it with `create_issue` and carry on."}

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
