defmodule CodeMySpec.MainAgent.WorkRepository do
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
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc "What each running agent on this project is doing."
  @spec list_agent_work(Scope.t()) :: [AgentWork.t()]
  def list_agent_work(%Scope{} = scope) do
    agents = Agents.list_running(scope)

    copies = working_copies(agents)
    last_said = last_said_at(agents)
    questions = open_questions(agents)
    tapped_out = tapped_out(agents)
    problems = problems_by_copy(scope)
    idle_roles = idle_roles(scope, agents)
    stories = story_titles(agents)

    Enum.map(agents, fn agent ->
      copy = Map.get(copies, agent.working_copy_id)
      task = Agent.active_task(agent)

      %AgentWork{
        agent_id: agent.id,
        role: agent.role,
        agent_status: agent.status,
        working_copy_id: agent.working_copy_id,
        working_copy_root: copy && copy.root,
        task_name: task && task.requirement_name,
        task_started_at: task && task.started_at,
        story_title: task && Map.get(stories, task.story_id),
        last_said_at: Map.get(last_said, agent.id),
        blocked_reasons: Map.get(questions, agent.id, []),
        tapped_out?: MapSet.member?(tapped_out, agent.id),
        turn_started_at: agent.turn_started_at,
        # A claimed task means there is work whatever the queue says; idle is
        # only ever about an agent with nothing in hand.
        idle?: is_nil(task) and MapSet.member?(idle_roles, agent.role),
        machine_tools: copy && copy.machine_tools,
        problems: Map.get(problems, agent.working_copy_id, [])
      }
    end)
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

  # `tap_out` writes a pending permission request against the agent, which is
  # the same row `Notifications.awaiting_answer?/1` and the stop decision read.
  defp tapped_out(agents) do
    ids = Enum.map(agents, & &1.id)

    from(p in PermissionRequest,
      where: p.agent_id in ^ids and p.status == "pending" and p.tool_name == "tap_out",
      select: p.agent_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # Every checkout's problems in one read, keyed by copy.
  #
  # `Problems.list_project_problems/2` narrows to the scope's own working copy,
  # which is right for a stop decision and wrong here: this view is about
  # somebody else's checkout as much as its own.
  defp problems_by_copy(%Scope{active_project_id: project_id}) do
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
    |> Enum.group_by(& &1.working_copy_id)
  end

  # Which roles the graph currently holds nothing for.
  #
  # Asked of the graph rather than read off a field, because there is no field:
  # "nothing to do" is a property of the project's outstanding work and an
  # implementation reporting it from somewhere a scenario had set would pass a
  # scenario and fail in production, where nobody sets it.
  defp idle_roles(scope, agents) do
    agents
    |> Enum.map(& &1.role)
    |> Enum.uniq()
    |> Enum.filter(&(Requirements.actionable_count(scope, &1) == 0))
    |> MapSet.new()
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
end
