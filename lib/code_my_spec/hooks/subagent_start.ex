defmodule CodeMySpec.Hooks.SubagentStart do
  @moduledoc """
  The SubagentStart hook — register a sub-agent against its parent session.

  Database only. Registration is what lets the stop hook attribute a file edit
  to the sub-agent that made it rather than to the main agent.
  """

  require Logger

  alias CodeMySpec.Sessions

  @spec handle(CodeMySpec.Users.Scope.t(), map()) :: {pos_integer(), map()}
  def handle(scope, params) do
    session_id = Map.get(params, "session_id")
    agent_id = Map.get(params, "agent_id")
    agent_name = Map.get(params, "agent_name")

    cond do
      is_nil(session_id) or session_id == "" ->
        refuse("session_id", params)

      is_nil(agent_id) or agent_id == "" ->
        refuse("agent_id", params)

      true ->
        register(scope, session_id, agent_id, agent_name)
    end
  end

  # A refusal that names a missing field and records nothing about what arrived.
  #
  # Four of these in two days (3bc0a83a) could not be diagnosed from either
  # side: `register/4` logs, this path did not, so the only trace was the
  # harness quoting `{"error":"agent_id is required"}` back — which says what
  # was wanted and nothing about what was sent.
  #
  # It matters because the refusal is rare rather than systematic. `web.log`
  # carries ten successful registrations over the same period, including ones
  # from ordinary Task-tool subagents, so Claude Code does send `agent_id` on
  # the normal path. Whatever produces these four is an edge case, and an edge
  # case you cannot see is one you cannot fix — the temptation is then to make
  # the field optional, which would silently cost R5a its runtime claim
  # (`Task.agent_id != nil`) to buy quiet.
  #
  # Keys only, never values: hook payloads carry prompts and transcripts.
  # `session_id` is an id and is safe to name; it is also the thing that lets
  # this be correlated with the rest of the session's log lines.
  defp refuse(field, params) do
    Logger.warning(
      "[SubagentStartHook] refused: #{field} missing or blank. " <>
        "session=#{inspect(params["session_id"])} agent_type=#{inspect(params["agent_type"])} " <>
        "payload carried: #{payload_keys(params)}"
    )

    {400, %{error: "#{field} is required"}}
  end

  defp payload_keys(params) when is_map(params) do
    params |> Map.keys() |> Enum.sort() |> Enum.join(", ")
  end

  defp payload_keys(_params), do: "a non-map body"

  defp register(scope, session_id, agent_id, agent_name) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        {404, %{error: "Session not found: #{session_id}"}}

      session ->
        attrs = %{
          agent_id: agent_id,
          agent_name: agent_name,
          last_heartbeat_at: DateTime.utc_now()
        }

        case Sessions.register_subagent(scope, session, attrs) do
          {:ok, updated} ->
            entry = Enum.find(updated.subagents, &(&1.agent_id == agent_id))
            Logger.info("[SubagentStartHook] Registered #{agent_id} on session #{session_id}")
            {200, %{agent_id: entry.agent_id, agent_name: entry.agent_name}}

          {:error, changeset} ->
            {422, %{error: inspect(changeset.errors)}}
        end
    end
  end
end
