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
        {400, %{error: "session_id is required"}}

      is_nil(agent_id) or agent_id == "" ->
        {400, %{error: "agent_id is required"}}

      true ->
        register(scope, session_id, agent_id, agent_name)
    end
  end

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
