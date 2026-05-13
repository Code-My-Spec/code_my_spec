defmodule CodeMySpecLocalWeb.Hooks.SubagentStartController do
  @moduledoc """
  Handles the SubagentStart hook event (Story 704).

  Registers a sub-agent on the session by `agent_id`. If the agent_id is
  already registered, refreshes its `last_heartbeat_at` (re-register to
  outlive TTL, per Rule 2). Returns 200 with the registration on
  success, 4xx on missing required fields.

  Idempotent on `agent_id`: calling subagent-start twice for the same
  agent yields one registration with the latest heartbeat.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Sessions

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")
    agent_id = Map.get(params, "agent_id")
    agent_name = Map.get(params, "agent_name")

    cond do
      is_nil(session_id) or session_id == "" ->
        conn |> put_status(400) |> json(%{error: "session_id is required"})

      is_nil(agent_id) or agent_id == "" ->
        conn |> put_status(400) |> json(%{error: "agent_id is required"})

      true ->
        register(conn, scope, session_id, agent_id, agent_name)
    end
  end

  defp register(conn, scope, session_id, agent_id, agent_name) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Session not found: #{session_id}"})

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
            json(conn, %{agent_id: entry.agent_id, agent_name: entry.agent_name})

          {:error, changeset} ->
            conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})
        end
    end
  end
end
