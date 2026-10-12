defmodule CodeMySpec.AgentPerformance.Page do
  @moduledoc """
  The performance page's whole read, in a fixed number of queries.

  `Index.load/1` used to ask `AgentPerformance.story_report/2` once per story
  and `team_first_pass_rate/3` once per team, and each of those re-read the
  project's sessions, agents, attempts and turns from scratch. On a real
  project (166 stories, 180 agents) that was ~13,000 queries and ~21s, and the
  LiveView join never completed: the chart and the filter form were
  unreachable behind it (issue 844907e0).

  Nothing here is a different answer to the same question. The per-story and
  per-team functions still exist, still mean what they meant, and are still
  what the show page and the criteria use. This reads the same tables once
  each, groups them in memory, and hands back the shape `Index` renders:

    * `stories` -- the project's active stories,
    * `reports` -- `%{story_id => story_report}`,
    * `teams` -- `%{working_copy_id => first_pass_rate}`,
    * `summary` -- the project-wide summary, off the same reads,
    * `agents` -- every agent, for the page's agent filter.

  The cost is a constant number of queries whatever the project's size: the
  stories, the sessions, the agents, the QA attempts, the turns, the agent
  messages and the app restarts, plus `OfferHealth`'s and the open questions'
  own reads. What is *not* here is a read per story or per agent -- that shape
  is the regression, and a test bounds the count so it cannot come back
  (`the_page_costs_queries_for_stories_not_one_each_test.exs`).
  """

  import Ecto.Query

  alias CodeMySpec.AgentPerformance.AgentTurn
  alias CodeMySpec.AgentPerformance.CycleTime
  alias CodeMySpec.AgentPerformance.OfferHealth
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @large_limit 100_000

  @type page :: %{
          stories: [Story.t()],
          reports: %{integer() => map()},
          teams: %{Ecto.UUID.t() => float() | nil},
          summary: map(),
          agents: [Agent.t()]
        }

  @doc "Everything the performance page renders, read in a fixed number of queries."
  @spec load(Scope.t()) :: page()
  def load(%Scope{} = scope) do
    stories = list_stories(scope)
    agents = list_agents(scope)
    attempts = project_attempts(scope)
    turns = project_turns(scope)
    messages = agent_messages(scope, agents)
    tasks = project_tasks(scope, stories, agents)

    %{
      stories: stories,
      agents: agents,
      reports: reports(scope, stories, tasks, agents, attempts, messages, turns),
      teams: teams(agents, stories, attempts),
      summary: summary(scope, agents, stories, messages)
    }
  end

  @doc """
  Every agent this project has, for the page's agent filter (criteria 2051,
  2053) and for the summary's own rows. Scoped to the project the same way
  `Agents.list_agents/1` is.
  """
  @spec list_agents(Scope.t()) :: [Agent.t()]
  def list_agents(%Scope{active_project_id: nil}), do: []

  def list_agents(%Scope{} = scope) do
    Agent
    |> where([a], a.project_id == ^scope.active_project_id)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @doc "Every story this project holds, for building a performance report over all of them."
  @spec list_stories(Scope.t()) :: [Story.t()]
  def list_stories(%Scope{} = scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
    end
  end

  # -- the page's own reads, one query apiece ------------------------------

  # `CycleTime.story/2` reads a story's tasks off its sessions and, separately,
  # off its agents -- two whole listings per story. Both are project-wide reads
  # underneath, so they are read once here and grouped by story.
  #
  # A task's own story_id, when it has one, is the only story it belongs to
  # -- grouping by story_id alone would otherwise put a component-scoped
  # task (never given a story_id, see `StartTask.build_entity_refs/2`) under
  # key `nil`, where no real story's `Map.get(tasks, story.id, [])` could
  # ever reach it. Such a task's only reference is its component, which can
  # be shared by several stories, so it counts toward every story sharing
  # that component -- never toward a sibling's own, separately story_id'd
  # tasks (issue 9c2107a6).
  defp project_tasks(scope, stories, agents) do
    story_ids = MapSet.new(stories, & &1.id)

    component_to_story_ids =
      stories
      |> Enum.reject(&is_nil(&1.component_id))
      |> Enum.group_by(& &1.component_id, & &1.id)

    session_tasks =
      from(s in Session, where: s.project_id == ^scope.active_project_id)
      |> Repo.all()
      |> Enum.flat_map(& &1.tasks)

    (session_tasks ++ Enum.flat_map(agents, & &1.tasks))
    |> Enum.flat_map(&task_story_pairs(&1, story_ids, component_to_story_ids))
    |> Enum.group_by(fn {story_id, _task} -> story_id end, fn {_story_id, task} -> task end)
  end

  defp task_story_pairs(%{story_id: story_id} = task, story_ids, _component_to_story_ids)
       when not is_nil(story_id) do
    if MapSet.member?(story_ids, story_id), do: [{story_id, task}], else: []
  end

  defp task_story_pairs(%{component_id: component_id} = task, _story_ids, component_to_story_ids)
       when not is_nil(component_id) do
    component_to_story_ids |> Map.get(component_id, []) |> Enum.map(&{&1, task})
  end

  defp task_story_pairs(_task, _story_ids, _component_to_story_ids), do: []

  defp project_attempts(%Scope{active_project_id: nil}), do: []

  defp project_attempts(%Scope{} = scope) do
    QaAttempt
    |> join(:inner, [a], s in Story, on: s.id == a.story_id)
    |> where([a, s], s.project_id == ^scope.active_project_id)
    |> order_by([a], desc: a.submitted_at, desc: a.id)
    |> preload(:invalidations)
    |> Repo.all()
    |> Enum.reject(&match?([_ | _], &1.invalidations))
  end

  defp project_turns(%Scope{active_account_id: nil}), do: []

  defp project_turns(%Scope{} = scope) do
    from(t in AgentTurn, where: t.account_id == ^scope.active_account_id)
    |> Repo.all()
  end

  # One read of every agent's own transcript, carrying the agent id from the
  # conversation so nothing downstream needs to look one up again. `:operator`
  # is the nudges and restarts interventions are counted from; `:tool` is the
  # tool results `ToolFailures` counts.
  #
  # Three raw columns and the id of the agent whose conversation they are --
  # not the rows themselves, and not every kind of message. What the counts
  # below read is `:role`, `:sender_id` and `:tool_failed`; `reason_text/1`
  # reads a message's `:content` only for the ones that are actually
  # interventions, and those come from their own read.
  #
  # Narrowing to those roles is the difference between reading the project's
  # transcript and reading what this page reports on. On the 188-agent project
  # this page is measured on there are 126,990 messages, 33,695 of them
  # `:operator` and 2,546 `:tool`; the rest is assistant prose nothing here
  # counts, and pulling it across was most of the async read (issue b118c546).
  #
  # The select is a plain map rather than a struct update: `Message` carries no
  # `agent_id` field -- the id lives on the conversation -- so `%{m | agent_id:
  # c.agent_id}` raises `KeyError` the moment a row matches. It never fired in
  # the test that bounded this read, whose fixtures matched no messages at all;
  # that test now builds messages these filters return.
  defp agent_messages(%Scope{active_project_id: nil}, _agents), do: []

  defp agent_messages(%Scope{} = scope, agents) do
    agent_ids = Enum.map(agents, & &1.id)

    if agent_ids == [] do
      []
    else
      conversation_ids(scope, agent_ids)
      |> counted_messages()
    end
  end

  # The conversations of the agents in hand, by id. Read rather than joined:
  # the ids are what the messages are filtered by, and a join back through
  # `conversations` to find them is the query this avoids.
  defp conversation_ids(%Scope{} = scope, agent_ids) do
    Conversation
    |> where([c], c.project_id == ^scope.active_project_id and c.agent_id in ^agent_ids)
    |> select([c], {c.id, c.agent_id})
    |> Repo.all()
    |> Map.new()
  end

  defp counted_messages(conversations) do
    conversation_ids = Map.keys(conversations)

    counted =
      Message
      |> where([m], m.conversation_id in ^conversation_ids)
      |> where([m], m.role in [:operator, :tool])
      |> select([m], %{
        id: m.id,
        conversation_id: m.conversation_id,
        role: m.role,
        sender_id: m.sender_id,
        tool_failed: m.tool_failed,
        inserted_at: m.inserted_at
      })
      |> limit(@large_limit)
      |> Repo.all()

    interventions =
      Message
      |> where([m], m.conversation_id in ^conversation_ids)
      |> where([m], m.role == :operator and m.sender_id in ["operator", "system:restart"])
      |> select([m], {m.id, m.content})
      |> limit(@large_limit)
      |> Repo.all()
      |> Map.new()

    Enum.map(counted, fn message ->
      message
      |> Map.put(:content, Map.get(interventions, message.id, []))
      |> Map.put(:agent_id, Map.fetch!(conversations, message.conversation_id))
    end)
  end

  # -- per-story reports, off those reads ---------------------------------

  defp reports(scope, stories, tasks, agents, attempts, messages, turns) do
    attempts_by_story = Enum.group_by(attempts, & &1.story_id)
    turns_by_story = Enum.group_by(turns, & &1.story_id)
    interventions_by_story = interventions_by_story(agents, messages)

    Map.new(stories, fn story ->
      story_tasks = Map.get(tasks, story.id, [])

      {story.id,
       %{
         cycle_time: CycleTime.story(scope, story, story_tasks),
         qa_rounds: qa_rounds(Map.get(attempts_by_story, story.id, [])),
         interventions: Map.get(interventions_by_story, story.id, []),
         tokens: tokens(Map.get(turns_by_story, story.id, []))
       }}
    end)
  end

  # `QaRounds.story/2`'s answer, from the story's slice of the project's
  # attempts. That function reverses `Qa.list_qa_attempts/2`'s newest-first
  # order, so its first is the earliest attempt -- and so is this one.
  defp qa_rounds([]), do: %{measured?: false, rounds: 0, first_time_pass?: false, findings: []}

  defp qa_rounds(attempts) do
    ordered = Enum.sort_by(attempts, & &1.submitted_at, {:asc, DateTime})

    %{
      measured?: true,
      rounds: length(ordered),
      first_time_pass?: hd(ordered).status == :pass,
      findings: ordered |> Enum.filter(&(&1.status != :pass)) |> Enum.flat_map(&observations/1)
    }
  end

  defp observations(%QaAttempt{scenarios: scenarios}) do
    scenarios
    |> Enum.filter(&(&1.status != :pass))
    |> Enum.map(& &1.observation)
    |> Enum.reject(&is_nil/1)
  end

  # `Interventions.story/2` attributes an intervention by the agent's own
  # `story_id` at read time: the story the agent holds now, not the story the
  # message happened to land beside. An agent between stories therefore counts
  # against none, and is counted at project level instead.
  defp interventions_by_story(agents, messages) do
    by_agent = Enum.group_by(messages, & &1.agent_id)

    agents
    |> Enum.reject(&is_nil(&1.story_id))
    |> Enum.group_by(& &1.story_id)
    |> Map.new(fn {story_id, holders} ->
      {story_id,
       holders
       |> Enum.flat_map(&Map.get(by_agent, &1.id, []))
       |> Enum.flat_map(&classify/1)}
    end)
  end

  defp classify(%{role: :operator, sender_id: "operator"} = message),
    do: [%{at: message.inserted_at, kind: :nudge, reason: reason_text(message)}]

  defp classify(%{role: :operator, sender_id: "system:restart"} = message),
    do: [%{at: message.inserted_at, kind: :restart, reason: reason_text(message)}]

  defp classify(_message), do: []

  defp reason_text(%{content: parts}) do
    parts
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  # `TokenUsage.for_story/2`, off the project's turns rather than a read each.
  defp tokens(turns) do
    with_usage = Enum.filter(turns, &(&1.input_tokens || &1.output_tokens))

    %{
      total: total_in_out(with_usage),
      by_provider:
        with_usage
        |> Enum.group_by(& &1.provider)
        |> Enum.reject(fn {provider, _rows} -> is_nil(provider) end)
        |> Map.new(fn {provider, rows} -> {provider, total_in_out(rows)} end)
    }
  end

  defp total_in_out([]), do: :unknown

  defp total_in_out(turns) do
    Enum.reduce(turns, 0, fn t, acc -> acc + (t.input_tokens || 0) + (t.output_tokens || 0) end)
  end

  # -- the teams' first-pass rates ----------------------------------------

  # `QaRounds.team_first_pass_rate/3` reads every project attempt once per
  # team. One pass over the attempts, grouped by the submitting agent's own
  # working copy, gives every team its rate at once. The denominator is a
  # team's stories, so one attempt per story -- the earliest, win or lose.
  defp teams(agents, stories, attempts) do
    copies = Map.new(agents, &{&1.id, &1.working_copy_id})

    first_pass_rates =
      attempts
      |> Enum.group_by(&Map.get(copies, &1.agent_id))
      |> Enum.reject(fn {working_copy_id, _attempts} -> is_nil(working_copy_id) end)
      |> Map.new(fn {working_copy_id, group} -> {working_copy_id, first_pass_rate(group)} end)

    # A team that only promotes, with no QA attempt on record, has no
    # first-pass rate but still belongs here for its throughput.
    promoting_team_ids =
      stories
      |> Enum.flat_map(&[&1.working_copy_id, &1.promoted_working_copy_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce(promoting_team_ids, first_pass_rates, &Map.put_new(&2, &1, nil))
  end

  defp first_pass_rate(attempts) do
    firsts =
      attempts
      |> Enum.group_by(& &1.story_id)
      |> Enum.map(fn {_story_id, story_attempts} ->
        Enum.min_by(story_attempts, & &1.submitted_at, DateTime)
      end)

    case firsts do
      [] -> nil
      list -> Enum.count(list, &(&1.status == :pass)) / length(list)
    end
  end

  # -- the project-wide summary -------------------------------------------

  defp summary(scope, agents, stories, messages) do
    %{
      agents: agent_rows(agents, messages),
      offer_health: OfferHealth.by_role(scope, nil),
      throughput_by_team: throughput(stories),
      project_level_interventions: project_interventions(scope, agents, messages),
      project_level_blocked: project_blocked(scope)
    }
  end

  # `ToolFailures.for_agent/2` and `Reliability.for_agent/2` each re-read one
  # conversation and one agent row; both are already in hand.
  defp agent_rows(agents, messages) do
    by_agent = messages |> Enum.filter(&(&1.role == :tool)) |> Enum.group_by(& &1.agent_id)

    Enum.map(agents, fn agent ->
      calls = Map.get(by_agent, agent.id, [])
      failed = Enum.filter(calls, & &1.tool_failed)

      %{
        agent_id: agent.id,
        role: agent.role,
        provider: agent.provider,
        tool_failures: %{
          total_calls: length(calls),
          failed_calls: length(failed),
          failure_rate: rate(failed, calls),
          by_tool: failed |> Enum.map(&tool_name/1) |> Enum.frequencies()
        },
        reliability: reliability(agent)
      }
    end)
  end

  defp rate(_failed, []), do: nil
  defp rate(failed, calls), do: length(failed) / length(calls)

  defp tool_name(%{sender_id: "agent:" <> name}), do: name
  defp tool_name(_message), do: "unknown"

  # `Reliability.for_agent/2` fetches the agent row this already has.
  defp reliability(%{provider_refusal: cause, provider_refused_at: %DateTime{} = at})
       when is_binary(cause),
       do: [%{at: at, cause: cause}]

  defp reliability(_agent), do: []

  # `Throughput.by_team/2` filters the project's stories, which are in hand.
  defp throughput(stories) do
    stories
    |> Enum.filter(&(not is_nil(&1.promoted_version)))
    |> Enum.group_by(&(&1.promoted_working_copy_id || &1.working_copy_id))
    |> Map.new(fn {working_copy_id, promoted} -> {working_copy_id, length(promoted)} end)
  end

  # `Interventions.project_level/1`: the agents holding no story, plus the app
  # restarts that named no agent at all. The agents and their messages are in
  # hand; the restarts are one read.
  defp project_interventions(scope, agents, messages) do
    by_agent = Enum.group_by(messages, & &1.agent_id)

    held =
      agents
      |> Enum.filter(&is_nil(&1.story_id))
      |> Enum.flat_map(&Map.get(by_agent, &1.id, []))
      |> Enum.flat_map(&classify/1)

    restarts =
      scope
      |> Agents.list_app_restarts_without_story()
      |> Enum.map(&%{at: &1.inserted_at, kind: :restart, reason: &1.reason})

    Enum.sort_by(held ++ restarts, & &1.at, DateTime)
  end

  # `BlockedTime.project_level/1` reads the main agent's own open questions --
  # the same listing `StopDecision.wake/2` obeys, rather than a second opinion
  # over `question_requests`/`permission_requests`.
  defp project_blocked(scope) do
    scope
    |> MainAgent.list_open_questions()
    |> Enum.map(fn open ->
      %{
        cause: if(open.kind == :permission, do: :tap_out, else: :question),
        waiting_on: if(open.holder == "main_agent", do: :main_agent, else: :user),
        seconds: DateTime.diff(DateTime.utc_now(), open.asked_at),
        resolved?: false
      }
    end)
  end
end
