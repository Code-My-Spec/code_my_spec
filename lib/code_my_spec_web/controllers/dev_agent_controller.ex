defmodule CodeMySpecWeb.DevAgentController do
  @moduledoc """
  Reach any agent on this machine, across projects, from a terminal.

  Behind `:dev_routes`, so compile-time absent from the release: a
  cross-project surface must not ship by accident. It does not share code with
  the `message_agent` MCP tool, which keeps its project scope; loosening one
  must not loosen the other.

      GET  /dev/agents                              list (`?project_id=`, `?all=true`)
      POST /dev/agents/<agent_id>/message           {"message": "…"} (`?wait=true` to wait)
      POST /dev/agents/<agent_id>/stop | restart | turn_on
      GET  /dev/agents/<agent_id>/questions
      POST /dev/agents/<agent_id>/answer            {"answer": "…", "question_id": "…"}
      POST /dev/copies/<working_copy_id>/staff      {"roles": ["coding"]}
      POST /dev/copies/<working_copy_id>/continuous {"continuous": false}
      POST /dev/copies/<working_copy_id>/machine_tools {"tools": [...]}

  Pass `question_id` to `answer` whenever you have one: without it the oldest
  pending question is answered. A message to a stopped agent is a 409
  `not_running`, not a failure.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Agents
  alias CodeMySpec.Notifications
  alias CodeMySpec.WorkingCopies

  # Used only with `?wait=true`. The turn runs inside a `GenServer.call` with
  # this value, so it caps the turn rather than the wait.
  # See knowledge/web, "Dev agent controller".
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
          status: Agents.lifecycle(&1, Agents.Presence.ids(&1.project_id)),
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

  def staff(conn, %{"working_copy_id" => copy_id} = params) do
    case Agents.staff_any_copy(copy_id, roles(params["roles"])) do
      {:ok, result} ->
        json(conn, %{
          status: "staffed",
          working_copy_id: copy_id,
          started:
            Enum.map(
              result.started,
              &%{id: &1.id, role: &1.role, provider: &1.provider, model: &1.model}
            ),
          failed:
            Enum.map(result.failed, fn {role, reason} ->
              %{role: role, reason: inspect(reason)}
            end),
          off:
            Enum.map(
              result.off,
              &%{id: &1.id, role: &1.role, off_by: &1.off_by, off_reason: &1.off_reason}
            ),
          continuous: result.continuous
        })

      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: inspect(reason), working_copy_id: copy_id})
    end
  end

  # `{"roles": ["coding"]}` staffs those roles instead of the copy's home roles
  # (one agent per role per checkout). Matched by name against `Agent.roles/0`,
  # never converted to atoms from the body; the full set so `:main` is allowed.
  defp roles(nil), do: nil

  defp roles(names) when is_list(names) do
    case Enum.filter(CodeMySpec.Agents.Agent.roles(), &(to_string(&1) in names)) do
      [] -> nil
      picked -> picked
    end
  end

  defp roles(_), do: nil

  # Toggles a copy's continuous flag without restarting its agents.
  def continuous(conn, %{"working_copy_id" => copy_id} = params) do
    wanted = truthy(params["continuous"])

    case Agents.set_any_copy_continuous(copy_id, wanted) do
      {:ok, count} ->
        json(conn, %{
          status: "ok",
          working_copy_id: copy_id,
          continuous: wanted,
          agents_updated: count
        })

      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: inspect(reason), working_copy_id: copy_id})
    end
  end

  # Sets one copy's `machine_tools` by hand, so QA can reach "a machine that can
  # drive nothing" without breaking a shared MCP client. `[]` is written
  # literally: it is a fault, while nil (never reported) is not. The next
  # harness join overwrites it.
  def machine_tools(conn, %{"working_copy_id" => copy_id} = params) do
    tools = params["tools"] || []

    with true <- is_list(tools),
         {:ok, copy} <- WorkingCopies.fetch(copy_id) do
      :ok = WorkingCopies.record_machine_tools(copy, tools)
      json(conn, %{status: "recorded", working_copy_id: copy_id, machine_tools: tools})
    else
      false ->
        conn |> put_status(422) |> json(%{error: ~s("tools" must be a list of names)})

      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: inspect(reason), working_copy_id: copy_id})
    end
  end

  # Absent means on. This route starts a loop as often as it stops one, and a
  # missing flag reading as "off" would make the shorter call the surprising one.
  defp truthy(nil), do: true
  defp truthy(value) when is_boolean(value), do: value
  defp truthy(value) when value in ["false", "0", "no", "off"], do: false
  defp truthy(_value), do: true

  # Restart, not start: same row, id and transcript. Starting would key a new
  # conversation and lose the thread.
  def restart(conn, %{"agent_id" => agent_id}) do
    case Agents.restart_any_agent(agent_id) do
      {:ok, agent} ->
        json(conn, %{
          status: to_string(agent.status),
          agent_id: agent.id,
          role: agent.role,
          project_id: agent.project_id
        })

      {:error, :no_such_agent} ->
        conn |> put_status(404) |> json(%{error: "no agent with id #{agent_id}"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason), agent_id: agent_id})
    end
  end

  # What an agent is waiting on. Free-text and option questions alike are
  # answered by text through `answer/2`.
  def questions(conn, %{"agent_id" => agent_id}) do
    requests = Notifications.list_question_requests_for_agent(agent_id)

    json(conn, %{
      agent_id: agent_id,
      requests: Enum.map(requests, &render_request/1)
    })
  end

  # Without `question_id`, answers the oldest pending question. With one that
  # does not match, 404s with the pending ids and never falls back: answers are
  # permanent.
  # See knowledge/web, "Dev agent controller".
  def answer(conn, %{"agent_id" => agent_id} = params) do
    given = answers_from(params)
    wanted = params["question_id"]

    case pending_request(agent_id, wanted) do
      nil when is_binary(wanted) ->
        pending = agent_id |> pending_requests() |> Enum.map(& &1.id)

        conn
        |> put_status(404)
        |> json(%{
          error: "no pending question #{wanted} for agent #{agent_id}",
          agent_id: agent_id,
          pending: pending
        })

      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "no pending question for agent #{agent_id}", agent_id: agent_id})

      _request when given == [] ->
        conn
        |> put_status(422)
        |> json(%{error: ~s(give "answer" as a string, or "answers" as a list of strings)})

      request ->
        answers = zip_answers(request.questions, given)
        _ = Notifications.answer_question_request(request.id, answers)

        json(conn, %{status: "answered", request_id: request.id, answers: answers})
    end
  end

  defp pending_requests(agent_id) do
    agent_id
    |> Notifications.list_question_requests_for_agent()
    |> Enum.filter(&(&1.status == "pending"))
  end

  defp pending_request(agent_id, nil), do: agent_id |> pending_requests() |> List.first()

  defp pending_request(agent_id, question_id) when is_binary(question_id) do
    agent_id |> pending_requests() |> Enum.find(&(&1.id == question_id))
  end

  defp render_request(request) do
    %{
      id: request.id,
      status: request.status,
      questions: Enum.map(request.questions || [], &Map.get(&1, "question"))
    }
  end

  # Positional, because an HTTP caller has no form to name fields with. One
  # answer for one question is the overwhelming case; a list covers the rest.
  defp answers_from(%{"answers" => answers}) when is_list(answers),
    do: Enum.filter(answers, &is_binary/1)

  defp answers_from(%{"answer" => answer}) when is_binary(answer), do: [answer]
  defp answers_from(_params), do: []

  # Short lists answer what they can; the rest get "" rather than nothing, since
  # a missing key reads as unanswered and leaves the agent waiting.
  defp zip_answers(questions, given) do
    questions
    |> Enum.with_index()
    |> Map.new(fn {question, i} ->
      {Map.get(question, "question"), Enum.at(given, i, "")}
    end)
  end

  # Stopping is turning off; `turn_on/2` is the way back.
  def stop(conn, %{"agent_id" => agent_id}) do
    case Agents.turn_off_any_agent(agent_id) do
      {:ok, agent} ->
        json(conn, %{status: "off", agent_id: agent.id, role: agent.role})

      {:error, :no_such_agent} ->
        conn |> put_status(404) |> json(%{error: "no agent with id #{agent_id}"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason), agent_id: agent_id})
    end
  end

  def turn_on(conn, %{"agent_id" => agent_id}) do
    case Agents.turn_on_any_agent(agent_id) do
      {:ok, agent} ->
        json(conn, %{status: to_string(agent.status), agent_id: agent.id, role: agent.role})

      {:error, :no_such_agent} ->
        conn |> put_status(404) |> json(%{error: "no agent with id #{agent_id}"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: inspect(reason), agent_id: agent_id})
    end
  end

  # Dispatch unless the caller asked to wait: waiting caps the turn.
  defp wait_for(%{"wait" => wait}) when wait in ["true", "1"], do: @wait_timeout
  defp wait_for(_params), do: :no_wait
end
