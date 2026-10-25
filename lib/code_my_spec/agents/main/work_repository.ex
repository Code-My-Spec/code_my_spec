defmodule CodeMySpec.Agents.Main.WorkRepository do
  @moduledoc """
  Assembles what every agent on the project is doing.

  One pass per fact rather than one query per agent. The fleet is small and the
  facts are not on the agent row — the last thing said is in a conversation, a
  question is a notification, problems belong to a working copy — so this reads
  each of them once for the whole project and joins in memory.

  ## Project-wide, like everything else the main agent reads

  Criterion 3273. The agents of one project are spread across its checkouts, and
  a view scoped to the copy the main agent happens to be standing on answers a
  question about a subset while looking exactly as complete. "Has any agent done
  anything since the restart" was the question that found a four-hour outage and
  it is unanswerable from a partial fleet.

  ## Running agents only

  Unlike `MainAgent.QuestionsRepository`, which deliberately reads every agent:
  a question outlives the process that raised it and must, but "what is this
  agent doing" is a question about a process, and a stopped one is not doing
  anything. Story 1056 is where stopped agents get restarted; this is the view
  of the fleet as it is.
  """

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.TurnTimeout
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.Validation.Blocking
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc "What each running agent on this project is doing."
  @spec list_agent_work(Scope.t()) :: [AgentWork.t()]
  def list_agent_work(%Scope{} = scope) do
    agents = Agents.list_on_duty(scope)
    present = Agents.present_ids(scope)

    copies = working_copies(agents)
    last_said = last_said_at(agents)
    timeouts = turn_timeouts(agents)
    questions = open_questions(agents)
    tapped_out = tapped_out(agents)
    problems = problems_by_copy(scope)
    owners = AgentsRepository.list_agents(scope)
    stories = story_titles(agents)
    designing = designing(agents)

    Enum.map(agents, fn agent ->
      copy = Map.get(copies, agent.working_copy_id)
      task = current_task(agent)
      # Whether the graph holds work *this agent* would be offered.
      #
      # Asked of the graph rather than read off a field, because there is no field:
      # "nothing to do" is a property of the project's outstanding work and an
      # implementation reporting it from somewhere a scenario had set would pass a
      # scenario and fail in production, where nobody sets it.
      #
      # Per agent, at its own checkout, through `Work.claimable_work/3` — the same
      # answer that decides whether it is offered a turn. Asking once per role at
      # the caller's scope reported QA agents as having work each correctly said it
      # had none (2026-09-17); asking per checkout but ignoring claims reported an
      # agent STALLED whose only work a neighbour held, which `Work` never offers
      # and `start_task` refuses (4849f20b). Either way an agent that had stood down
      # correctly read identically to one that was stuck.
      {claimable, damped} = offer(scope, agent, Agent.active_task(agent), owners)

      %AgentWork{
        agent_id: agent.id,
        role: agent.role,
        agent_status: Agents.lifecycle(agent, present),
        external?: agent.engine in [:claude_code, :codex],
        working_copy_id: agent.working_copy_id,
        working_copy_root: copy && copy.root,
        issue_id: agent.issue_id,
        team_free?: not is_nil(agent.team_free_at),
        task_name: task && task.requirement_name,
        task_status: task && task.status,
        task_started_at: task && task.started_at,
        story_title: task && Map.get(stories, task.story_id),
        designing: Map.get(designing, agent.id),
        last_said_at: Map.get(last_said, agent.id),
        blocked_reasons: Map.get(questions, agent.id, []),
        tapped_out?: MapSet.member?(tapped_out, agent.id),
        turn_in_flight?: Offers.in_flight?(agent.id),
        unstarted_turn: Offers.unstarted_turn(agent.id),
        turn_started_at: agent.turn_started_at,
        continuous?: agent.continuous,
        provider_refusal: agent.provider_refusal,
        provider_retry_at: agent.provider_retry_at,
        turn_timeouts: Map.get(timeouts, agent.id),
        # An active task means there is work whatever the queue says. A blocked
        # one does not: it holds only itself (story 1080).
        idle?: is_nil(Agent.active_task(agent)) and claimable == [],
        damped: damped,
        machine_tools: copy && copy.machine_tools,
        problems: Map.get(problems, agent.working_copy_id, [])
      }
    end)
  end

  # An active task means nothing is being offered, so nothing can be damped.
  defp offer(_scope, _agent, active, _owners) when not is_nil(active), do: {[], nil}

  defp offer(scope, agent, nil, owners) do
    case Work.claimable_work(scope, agent, owners) do
      [] -> {[], nil}
      claimable -> {claimable, Work.damped(scope, agent, claimable)}
    end
  end

  # The work this agent is on, which is not only the active one.
  #
  # An agent that asked a question has no *active* task by construction — the
  # question blocked it — and reading only `active_task/1` reported that agent
  # as having nothing to do while the line below it said what it was blocked
  # on. Criterion 3275 is exactly this pair: the main agent is handed the parts
  # and draws its own conclusion, and "no task" beside "blocked on a question"
  # is two parts that contradict each other.
  #
  # Newest first among blocked attempts, because that is the one the agent is
  # waiting on now; older blocked attempts are history it has not cancelled.
  # Shown, not counted as work: `idle?` and the offer read the active task.
  defp current_task(agent) do
    Agent.active_task(agent) || latest_blocked_task(agent)
  end

  defp latest_blocked_task(%Agent{tasks: tasks}) do
    (tasks || [])
    |> Enum.filter(&(&1.status == :blocked))
    |> Enum.max_by(& &1.blocked_at, DateTime, fn -> nil end)
  end

  defp working_copies(agents) do
    ids = agents |> Enum.map(& &1.working_copy_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(w in WorkingCopy, where: w.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # When each agent last said anything, off its own conversation.
  #
  # The messages rather than `agents.updated_at`: the row moves for reasons that
  # have nothing to do with speaking — a status change, a task claimed, a reap
  # pass — and a view reading it would call a silent agent chatty, which is the
  # one direction this must not fail in.
  defp last_said_at(agents) do
    ids = Enum.map(agents, & &1.id)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: c.agent_id in ^ids,
      group_by: c.agent_id,
      select: {c.agent_id, max(m.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # How many of each agent's latest turns died on the provider CLI's timeout
  # (eb09b076). A failed turn is written as the agent's message carrying the
  # provider's error, so the run is its newest assistant rows that are timeouts.
  @timeout_window 20

  defp turn_timeouts(agents) do
    ids = Enum.map(agents, & &1.id)

    ranked =
      from(m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: c.agent_id in ^ids and m.role == :assistant,
        select: %{
          agent_id: c.agent_id,
          content: m.content,
          rank: over(row_number(), partition_by: c.agent_id, order_by: [desc: m.inserted_at])
        }
      )

    from(r in subquery(ranked),
      where: r.rank <= @timeout_window,
      order_by: [asc: r.rank],
      select: {r.agent_id, r.content}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &Message.text(%Message{content: elem(&1, 1)}))
    |> Enum.flat_map(fn {agent_id, texts} ->
      case TurnTimeout.streak(texts) do
        nil -> []
        streak -> [{agent_id, streak}]
      end
    end)
    |> Map.new()
  end

  # What each agent is waiting on, in the words it asked.
  #
  # A count or a flag would send the main agent to go and find out which
  # question, and the thing it needs is already in hand — criterion 3277.
  defp open_questions(agents) do
    ids = Enum.map(agents, & &1.id)

    from(q in QuestionRequest,
      where: q.agent_id in ^ids and q.status == "pending",
      order_by: [asc: q.inserted_at],
      select: {q.agent_id, q.questions}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {agent_id, questions}, acc ->
      Map.update(acc, agent_id, texts(questions), &(&1 ++ texts(questions)))
    end)
  end

  defp texts(questions) do
    Enum.map(questions, fn question -> MapAccess.get(question, :question) end)
  end

  # A pending tap-out naming no task, the one `Agents.Waiting` holds the agent
  # on. One naming a task holds only that task (story 1080).
  defp tapped_out(agents) do
    ids = Enum.map(agents, & &1.id)

    from(p in PermissionRequest,
      where:
        p.agent_id in ^ids and p.status == "pending" and p.tool_name == "tap_out" and
          is_nil(p.task_id),
      select: p.agent_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # Every checkout's problems that can block, in one read, keyed by copy.
  #
  # `Problems.list_project_problems/2` narrows to the scope's own working copy,
  # which is right for a stop decision and wrong here: this view is about
  # somebody else's checkout as much as its own.
  #
  # Only what `Blocking.can_block?/2` says may block. Advisory findings were
  # counted too, so every check-in put team 2 under "Needs you: 45 checkout
  # problems" for credo :info findings the gate passed on every batch, and a
  # main told forty-five things need it learns to skip the line (2026-10-13).
  defp problems_by_copy(%Scope{active_project_id: project_id} = scope) do
    advisory = Blocking.advisory_findings(scope)

    from(p in Problem,
      where: p.project_id == ^project_id,
      order_by: [asc: p.file_path, asc: p.line],
      select: %{
        working_copy_id: p.working_copy_id,
        source: p.source,
        severity: p.severity,
        file_path: p.file_path,
        line: p.line,
        message: p.message
      }
    )
    |> Repo.all()
    |> Enum.filter(&Blocking.can_block?(&1, advisory))
    |> Enum.group_by(& &1.working_copy_id)
  end

  # The story each task is against, by title.
  #
  # Titles rather than ids, because an id is a second lookup wearing the costume
  # of an answer — criterion 3271.
  defp story_titles(agents) do
    ids =
      agents
      |> Enum.map(&Agent.active_task/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.story_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    from(s in Story, where: s.id in ^ids, select: {s.id, s.title})
    |> Repo.all()
    |> Map.new()
  end

  # The epic each epic-scope agent (product) is designing, by name. Coding and
  # QA hold their team's epic too, but they build it rather than design it.
  defp designing(agents) do
    holders =
      for agent <- agents,
          RoleProfile.scope(agent.role) == :epic,
          is_binary(agent.epic_id),
          into: %{},
          do: {agent.id, agent.epic_id}

    names =
      from(e in Epic, where: e.id in ^Enum.uniq(Map.values(holders)), select: {e.id, e.name})
      |> Repo.all()
      |> Map.new()

    Map.new(holders, fn {agent_id, epic_id} -> {agent_id, Map.get(names, epic_id)} end)
  end
end
