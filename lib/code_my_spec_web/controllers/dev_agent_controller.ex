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
      POST /dev/agents/<agent_id>/answer    {"answer": "…", "question_id": "…"}
      GET  /dev/agents                      list, so you can find the id

  `question_id` on the answer route is optional and you should pass it whenever
  you have one: without it the *oldest* pending question is answered, which is
  how a caller once answered two questions belonging to somebody else.

  Answers what the agent said, or the transport's error. A message to a stopped
  agent is `{:error, :not_running}` and is reported as such rather than as a
  failure — an agent halted on purpose is not owed delivery.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Agents
  alias CodeMySpec.Notifications
  alias CodeMySpec.WorkingCopies

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

  def staff(conn, %{"working_copy_id" => copy_id}) do
    case Agents.staff_any_copy(copy_id) do
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
          continuous: result.continuous
        })

      {:error, reason} ->
        conn |> put_status(404) |> json(%{error: inspect(reason), working_copy_id: copy_id})
    end
  end

  # On and off without restarting anything. Staffing turns it on as a side
  # effect, which is the wrong grain when the question is "pause this copy" —
  # that used to mean stopping every agent on it and staffing again.
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

  # What a checkout can drive, set by hand.
  #
  # A working copy's `machine_tools` is written only by the harness, on join.
  # That made "a machine that can drive nothing" — the state `Machinery`
  # attributes a tool fault from, and the precondition of criteria 3272, 3310,
  # 3311 and 3312 — reachable only by breaking a real machine's MCP client,
  # which four other projects' checkouts share. Five QA passes refused on that
  # ground and left the criteria verified-by-reading (0fb7bf03).
  #
  # `[]` and `nil` are different answers and only one is a fault: a copy that
  # has never said what it can do is most of the fleet, and calling that broken
  # would report everything as unable to work. So an empty list is written
  # literally, not as an absence.
  #
  # Scoped to one copy, which is the whole point — `tool_fault/1` compares a
  # project's copies against each other, so a project of your own shows a
  # machine-wide fault or a single agent's without any other project seeing
  # either. The next harness join overwrites this; nothing here needs undoing.
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

  # The other direction, which these tools did not have.
  #
  # `/dev/agents` could list an agent and stop it, and nothing here could start
  # one again — so a stopped agent's only way back was the play control on its
  # conversation page, and while that control was broken there was no way back
  # at all. John, looking at exactly that: "I thought I could now start it with
  # the play button but it's stopped and I can't get it going again."
  #
  # Restart, not start: same row, same id, same transcript. Starting would key a
  # new conversation and lose the thread, which is the outcome a restart exists
  # to avoid.
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

  # What an agent is waiting on, and how to unblock it.
  #
  # An agent that asks a question stops and waits, and until now the only thing
  # that could answer was a person on the conversation page. So these tools
  # could start an agent, stop it and talk to it, and could not clear the one
  # state that makes it sit still — which meant an unattended run parked on a
  # question nobody was watching stayed parked.
  #
  # `send_message` and `ask_user_question` both land here: the first is a
  # free-text box, the second carries options. Both are answered the same way,
  # by text, because an option is just an answer somebody wrote down first.
  def questions(conn, %{"agent_id" => agent_id}) do
    requests = Notifications.list_question_requests_for_agent(agent_id)

    json(conn, %{
      agent_id: agent_id,
      requests: Enum.map(requests, &render_request/1)
    })
  end

  # `question_id` is optional and it exists because omitting it is dangerous.
  #
  # Without it this answers the agent's *oldest* pending question, which is fine
  # for a person poking at one stuck agent and wrong for anything holding an id.
  # On 2026-09-13 a caller clearing two questions it had just raised answered two
  # unrelated ones belonging to another agent instead: the agent had a backlog,
  # there was nowhere to say which question was meant, and the only feedback was
  # `request_id` in the response body — after the write. `Notifications` has no
  # un-answer path by design ("questions never expire"), so those answers are
  # permanent. Issue `2638fbf5`.
  #
  # The trap is aimed squarely at QA, which is the main caller: exercising
  # escalation *creates* questions, so the agent doing the exercising very often
  # has others open, and issue `7586cf46` recommends this endpoint for exactly
  # that cleanup.
  #
  # A mismatch lists the pending ids rather than falling back to the oldest.
  # Falling back is what this is here to stop — a caller that named the wrong
  # question wants to be told, not to have a different one answered for it.
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
