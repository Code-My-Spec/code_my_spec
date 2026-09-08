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

  # Only when the caller asked to wait, and short on purpose.
  #
  # `message_agent/4` runs the whole turn inside a `GenServer.call` with this
  # value, so it is not a patience setting — it is the agent's turn limit. A
  # four-minute wait made four-minute turns and reported the ones that outlived
  # it as failures, in the agent's own voice, while they carried on working.
  #
  # So waiting is opt-in (`?wait=true`) and for short exchanges: ask a question,
  # get an answer. Anything long — a QA pass, a browser scenario — is dispatched
  # and watched in the transcript, which is where it is legible anyway.
  @wait_timeout 240_000

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

  def message(conn, %{"agent_id" => agent_id, "message" => message} = params)
      when is_binary(message) and message != "" do
    case Agents.message_any_agent(agent_id, message, wait_for(params)) do
      {:ok, :still_working} ->
        json(conn, %{status: "still_working", agent_id: agent_id})

      {:ok, disposition} when disposition in [:started, :queued] ->
        json(conn, %{status: to_string(disposition), agent_id: agent_id})

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

  def stop(conn, %{"agent_id" => agent_id}) do
    case Agents.stop_any_agent(agent_id) do
      {:ok, agent} ->
        json(conn, %{status: "stopped", agent_id: agent.id, role: agent.role})

      {:error, :no_such_agent} ->
        conn |> put_status(404) |> json(%{error: "no agent with id #{agent_id}"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason), agent_id: agent_id})
    end
  end

  # Dispatch unless the caller asked to wait. The default matters: waiting is
  # what caps the turn, and the caller who forgets to think about it is the one
  # driving a long run.
  defp wait_for(%{"wait" => wait}) when wait in ["true", "1"], do: @wait_timeout
  defp wait_for(_params), do: :no_wait
end
