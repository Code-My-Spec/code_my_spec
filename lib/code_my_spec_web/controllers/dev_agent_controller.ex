defmodule CodeMySpecWeb.DevAgentController do
  @moduledoc """
  Talk to any agent on this machine, from a terminal, in development.

  `message_agent` resolves the agent inside the caller's project and refuses
  anything else, which is right — it is a tenant boundary and an operator's MCP
  session is bound to one project. It also means the person debugging why an
  agent is stuck cannot reach it unless they happen to be scoped to its project,
  and on 2026-09-07 that person was watching a QA agent fail the same way for
  four hours with no way to ask it anything.

  John: "you should have a dev rest endpoint or something that allows you to
  message these agents so that you can interact with them and work on getting
  these agents working."

  So: a route behind `:dev_routes`, which is compile-time. It does not exist in
  the release — not disabled, not guarded at runtime, absent — because a
  cross-project message surface is exactly the thing that must not ship by
  accident.

  ## What it does not do

  It does not widen `message_agent`. The tool keeps its project scope and its
  refusal; this is a separate door for a separate caller, and the two do not
  share code precisely so that loosening one cannot loosen the other.

      POST /dev/agents/<agent_id>/message   {"message": "…"}
      GET  /dev/agents                      list, so you can find the id

  Answers what the agent said, or the transport's error. A message to a stopped
  agent is `{:error, :not_running}` and is reported as such rather than as a
  failure — an agent halted on purpose is not owed delivery.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Agents

  # Long, because this waits for the agent's turn. `message_agent/4` runs the
  # whole turn inside the call — that is the point here, unlike the analysis and
  # answer paths, where the caller is a process that must not block. A person at
  # a terminal wants the reply.
  @turn_timeout 240_000

  def index(conn, params) do
    agents =
      Agents.list_every_agent(
        project_id: params["project_id"],
        include_stopped: params["all"] == "true"
      )
      |> Enum.map(
        &%{
          id: &1.id,
          role: &1.role,
          status: &1.status,
          engine: &1.engine,
          continuous: &1.continuous,
          project_id: &1.project_id,
          working_copy: &1.working_copy
        }
      )

    json(conn, %{agents: agents})
  end

  def message(conn, %{"agent_id" => agent_id, "message" => message})
      when is_binary(message) and message != "" do
    case Agents.message_any_agent(agent_id, message, @turn_timeout) do
      {:ok, :still_working} ->
        json(conn, %{status: "still_working", agent_id: agent_id})

      {:ok, said} ->
        json(conn, %{status: "ok", agent_id: agent_id, said: said})

      {:error, :no_such_agent} ->
        conn |> put_status(404) |> json(%{error: "no agent with id #{agent_id}"})

      {:error, :not_running} ->
        conn
        |> put_status(409)
        |> json(%{error: "not_running", agent_id: agent_id, hint: "start it first"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason), agent_id: agent_id})
    end
  end

  def message(conn, %{"agent_id" => _}) do
    conn |> put_status(422) |> json(%{error: "message is required and must not be empty"})
  end
end
