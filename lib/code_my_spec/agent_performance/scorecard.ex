defmodule CodeMySpec.AgentPerformance.Scorecard do
  @moduledoc """
  The performance page's headline rates, this week against last, and the
  breakdowns behind them -- the structure of the one-off scorecard story 1092
  grew from (operator, 2026-10-04): what stands out, activity by role, QA,
  blocked time, offers, what to change first.

  One read of the last 14 days, then every rate is computed in memory for
  this week, last week and each of this week's days (the sparklines). Narrowed
  by the page's filter through the agents it leaves; a story filter keeps the
  agents holding that story.
  """

  import Ecto.Query

  alias CodeMySpec.AgentPerformance.AgentTurn
  alias CodeMySpec.AgentPerformance.MessageKind
  alias CodeMySpec.AgentPerformance.OfferHealth
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @day 86_400
  @week 7 * @day

  # direction: which way is better. warn/bad: absolute thresholds, in the
  # direction that is worse; a rate without them is judged on its change.
  @kpis [
    %{
      key: :throughput,
      title: "Stories promoted",
      format: :count,
      better: :up,
      section: "stories"
    },
    %{
      key: :qa_first_pass,
      title: "QA first-pass yield",
      format: :percent,
      better: :up,
      warn: 0.5,
      bad: 0.3,
      section: "qa"
    },
    %{
      key: :tap_out_expiry,
      title: "Tap-outs expired undecided",
      format: :percent,
      better: :down,
      warn: 0.1,
      bad: 0.25,
      section: "blocked"
    },
    %{
      key: :question_wait,
      title: "Median wait for an answer",
      format: :minutes,
      better: :down,
      warn: 60,
      bad: 240,
      section: "blocked"
    },
    %{
      key: :offer_acceptance,
      title: "Offer acceptance",
      format: :percent,
      better: :up,
      warn: 0.7,
      bad: 0.5,
      section: "offers"
    },
    %{
      key: :tool_failure_rate,
      title: "Tool failure rate",
      format: :percent,
      better: :down,
      warn: 0.05,
      bad: 0.1,
      section: "roles"
    },
    %{
      key: :failed_turns,
      title: "Failed turns",
      format: :count,
      better: :down,
      section: "activity"
    },
    %{
      key: :messages_per_story,
      title: "Messages per promoted story",
      format: :number,
      better: :down,
      warn: 10,
      bad: 25,
      section: "messages"
    },
    %{
      key: :tokens_per_story,
      title: "Tokens per promoted story",
      format: :tokens,
      better: :down,
      section: "roles"
    }
  ]

  # What to change first when a rate needs it -- the scorecard's own
  # recommendations, carried on the rate so the page and the export say the
  # same thing.
  @changes %{
    throughput:
      "Fewer stories landed than last week. Look at Time per story and Blocked time for where they are waiting.",
    qa_first_pass:
      "Raise QA first pass: have the coder run the QA brief's checks before certifying, and restart the copy's app onto the committed code before QA starts.",
    tap_out_expiry:
      "Never let a tap-out expire unseen: route undecided tap-outs to main after a short timeout, so main decides or escalates.",
    question_wait:
      "Get questions answered faster: have main try them first and escalate only real product calls.",
    offer_acceptance:
      "Find out why offers go unclaimed: Offers by kind shows which kinds are ignored or declined most.",
    tool_failure_rate:
      "Cut tool failures: Activity by role and the agent chart show which roles and agents fail most, and the tools behind it.",
    failed_turns:
      "Fewer failed turns: Activity over time shows when they cluster; the failure notices name the provider error.",
    messages_per_story:
      "Fewer messages per story: Time per story shows which stories needed the most, and what they waited on.",
    tokens_per_story: "Bring cost per story down: Activity by role compares tokens by provider."
  }

  @doc "The headline rates and the breakdowns behind them, narrowed by `filter`."
  @spec load(Scope.t(), map()) :: map()
  def load(%Scope{} = scope, filter \\ %{}) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -2 * @week, :second)
    agents = scope |> Agents.list_agents() |> narrow_agents(filter)
    data = read(scope, agents, filter, since)
    this_week = {DateTime.add(now, -@week, :second), now}

    %{
      kpis: Enum.map(@kpis, &kpi(&1, data, now)),
      roles: roles(data, this_week),
      tap_outs: by_role(data.tap_outs, data.agents, this_week, & &1.status),
      questions: questions(data, this_week),
      offer_kinds: offer_kinds(data.offers, this_week)
    }
  end

  # -- the read ------------------------------------------------------------

  defp read(scope, agents, filter, since) do
    ids = Enum.map(agents, & &1.id)
    by_id = Map.new(agents, &{&1.id, &1})

    %{
      agents: by_id,
      messages: messages(scope, ids, since),
      attempts: attempts(scope, by_id),
      stories: promoted_stories(scope, filter, since),
      tap_outs: requests(PermissionRequest, ids, since),
      questions: requests(QuestionRequest, ids, since),
      offers: offers(scope, by_id, since),
      turns: turns(scope, ids, since)
    }
  end

  defp narrow_agents(agents, filter) do
    Enum.filter(agents, fn agent ->
      Enum.all?(filter, fn
        {:story_id, id} -> agent.story_id == id
        {:working_copy_id, id} -> agent.working_copy_id == id
        {:agent_id, id} -> agent.id == id
        _other -> true
      end)
    end)
  end

  defp messages(_scope, [], _since), do: []

  defp messages(scope, ids, since) do
    Message
    |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
    |> where([m, c], c.project_id == ^scope.active_project_id and c.agent_id in ^ids)
    |> where([m], m.inserted_at >= ^since and m.role in [:operator, :tool, :assistant])
    |> select([m, c], %{
      agent_id: c.agent_id,
      role: m.role,
      sender_id: m.sender_id,
      failed: m.tool_failed,
      tool_call_id: m.tool_call_id,
      at: m.inserted_at,
      text:
        fragment(
          "CASE WHEN ? = 'operator' THEN left(ltrim(?->0->>'text'), 120) END",
          m.role,
          m.content
        )
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :kind, message_kind(&1)))
  end

  defp message_kind(%{role: :operator, sender_id: sender, text: text})
       when sender in ["operator", "system:restart", "promotion-notice"],
       do: MessageKind.of(sender, text || "")

  defp message_kind(_message), do: nil

  # Every attempt the agents left submitted, for each story's first.
  defp attempts(scope, by_id) do
    scope
    |> Qa.list_project_attempts(include_older: true)
    |> Enum.filter(&Map.has_key?(by_id, &1.agent_id))
  end

  defp promoted_stories(scope, filter, since) do
    stories =
      case Stories.list_project_stories(scope) do
        {:ok, stories} -> stories
        stories -> stories
      end

    Enum.filter(stories, fn story ->
      match?(%DateTime{}, story.promoted_at) and DateTime.compare(story.promoted_at, since) != :lt and
        Map.get(filter, :story_id, story.id) == story.id and
        Map.get(filter, :working_copy_id, copy_of(story)) == copy_of(story)
    end)
  end

  defp copy_of(story), do: story.promoted_working_copy_id || story.working_copy_id

  defp requests(_schema, [], _since), do: []

  defp requests(schema, ids, since) do
    schema
    |> where([r], r.agent_id in ^ids and r.inserted_at >= ^DateTime.truncate(since, :second))
    |> select([r], %{
      agent_id: r.agent_id,
      status: r.status,
      at: r.inserted_at,
      settled_at: r.updated_at
    })
    |> Repo.all()
  end

  defp offers(scope, by_id, since) do
    scope
    |> Offers.list(since: since, limit: 100_000)
    |> Enum.filter(&Map.has_key?(by_id, &1.agent_id))
  end

  defp turns(_scope, [], _since), do: []

  defp turns(scope, ids, since) do
    AgentTurn
    |> where([t], t.account_id == ^scope.active_account_id and t.agent_id in ^ids)
    |> where([t], t.inserted_at >= ^since)
    |> select([t], %{
      agent_id: t.agent_id,
      at: t.inserted_at,
      tokens: coalesce(t.input_tokens, 0) + coalesce(t.output_tokens, 0)
    })
    |> Repo.all()
  end

  # -- the rates -----------------------------------------------------------

  defp kpi(spec, data, now) do
    current = {DateTime.add(now, -@week, :second), now}
    previous = {DateTime.add(now, -2 * @week, :second), DateTime.add(now, -@week, :second)}
    value = rate(spec.key, data, current)
    before = rate(spec.key, data, previous)

    days =
      for d <- 6..0//-1 do
        to = DateTime.add(now, -d * @day, :second)
        rate(spec.key, data, {DateTime.add(to, -@day, :second), to})
      end

    spec
    |> Map.put(:change, Map.fetch!(@changes, spec.key))
    |> Map.put(:value, value)
    |> Map.put(:previous, before)
    |> Map.put(:days, days)
    |> Map.put(:severity, severity(spec, value, before))
  end

  defp rate(:throughput, data, window),
    do: data.stories |> within(window, & &1.promoted_at) |> length()

  defp rate(:qa_first_pass, data, window) do
    data.attempts
    |> Enum.group_by(& &1.story_id)
    |> Enum.map(fn {_story, attempts} -> Enum.min_by(attempts, & &1.submitted_at, DateTime) end)
    |> within(window, & &1.submitted_at)
    |> share(&(&1.status == :pass))
  end

  defp rate(:tap_out_expiry, data, window) do
    data.tap_outs
    |> within(window, & &1.at)
    |> Enum.filter(&(&1.status in ["approved", "denied", "expired"]))
    |> share(&(&1.status == "expired"))
  end

  defp rate(:question_wait, data, window) do
    data.questions
    |> within(window, & &1.at)
    |> Enum.filter(&(&1.status == "answered"))
    |> Enum.map(&(DateTime.diff(&1.settled_at, &1.at) / 60))
    |> median()
  end

  defp rate(:offer_acceptance, data, window) do
    data.offers
    |> within(window, & &1.inserted_at)
    |> Enum.filter(&(OfferHealth.counted?(&1) and &1.status in [:claimed, :ignored, :declined]))
    |> share(&(&1.status == :claimed))
  end

  defp rate(:tool_failure_rate, data, window) do
    data.messages
    |> Enum.filter(&(&1.role == :tool and &1.tool_call_id))
    |> within(window, & &1.at)
    |> share(& &1.failed)
  end

  defp rate(:failed_turns, data, window),
    do:
      data.messages
      |> Enum.filter(&(&1.kind == :failed_turn))
      |> within(window, & &1.at)
      |> length()

  defp rate(:messages_per_story, data, window) do
    sent =
      data.messages
      |> Enum.filter(&MessageKind.intervention?(&1.kind || :none))
      |> within(window, & &1.at)

    per_story(length(sent), rate(:throughput, data, window))
  end

  defp rate(:tokens_per_story, data, window) do
    tokens = data.turns |> within(window, & &1.at) |> Enum.map(& &1.tokens) |> Enum.sum()
    if tokens == 0, do: nil, else: per_story(tokens, rate(:throughput, data, window))
  end

  defp per_story(_total, 0), do: nil
  defp per_story(total, stories), do: total / stories

  defp severity(_spec, nil, _before), do: :none

  defp severity(%{warn: warn, bad: bad, better: better}, value, _before) do
    cond do
      worse_than?(value, bad, better) -> :bad
      worse_than?(value, warn, better) -> :warn
      true -> :good
    end
  end

  defp severity(%{better: better}, value, before) when is_number(before) and before != 0 do
    change = (value - before) / abs(before)
    change = if better == :down, do: -change, else: change

    cond do
      change < -0.25 -> :warn
      change > 0.1 -> :good
      true -> :none
    end
  end

  defp severity(_spec, _value, _before), do: :none

  defp worse_than?(value, limit, :up), do: value < limit
  defp worse_than?(value, limit, :down), do: value > limit

  # -- the breakdowns, this week ---------------------------------------------

  defp roles(data, window) do
    messages = within(data.messages, window, & &1.at)
    tokens = data.turns |> within(window, & &1.at) |> Enum.group_by(& &1.agent_id)

    messages
    |> Enum.group_by(&group_key(data.agents, &1.agent_id))
    |> Map.delete(nil)
    |> Enum.map(fn {{role, provider} = key, group} ->
      calls = Enum.filter(group, &(&1.role == :tool and &1.tool_call_id))

      agent_ids =
        data.agents
        |> Map.values()
        |> Enum.filter(&(group_key(data.agents, &1.id) == key))
        |> Enum.map(& &1.id)

      %{
        role: role,
        provider: provider,
        replies: Enum.count(group, &(&1.role == :assistant)),
        calls: length(calls),
        failed: Enum.count(calls, & &1.failed),
        failed_turns: Enum.count(group, &(&1.kind == :failed_turn)),
        tokens:
          agent_ids
          |> Enum.flat_map(&Map.get(tokens, &1, []))
          |> Enum.map(& &1.tokens)
          |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{to_string(&1.role), &1.provider || ""})
  end

  defp group_key(agents, id) do
    case Map.get(agents, id) do
      nil -> nil
      agent -> {agent.role, agent.provider}
    end
  end

  defp by_role(requests, agents, window, status_fn) do
    requests
    |> within(window, & &1.at)
    |> Enum.group_by(&role_of(agents, &1.agent_id))
    |> Map.new(fn {role, group} -> {role, Enum.frequencies_by(group, status_fn)} end)
  end

  defp questions(data, window) do
    data.questions
    |> within(window, & &1.at)
    |> Enum.group_by(&role_of(data.agents, &1.agent_id))
    |> Map.new(fn {role, group} ->
      waits =
        group
        |> Enum.filter(&(&1.status == "answered"))
        |> Enum.map(&(DateTime.diff(&1.settled_at, &1.at) / 60))

      {role,
       %{
         statuses: Enum.frequencies_by(group, & &1.status),
         median_minutes: median(waits),
         average_minutes: if(waits == [], do: nil, else: Enum.sum(waits) / length(waits))
       }}
    end)
  end

  defp offer_kinds(offers, window) do
    offers
    |> within(window, & &1.inserted_at)
    |> Enum.group_by(& &1.kind)
    |> Map.new(fn {kind, group} ->
      claimed = Enum.filter(group, &(&1.status == :claimed and &1.outcome_at))

      {kind,
       %{
         statuses: Enum.frequencies_by(group, & &1.status),
         average_seconds_to_claim:
           if(claimed == [],
             do: nil,
             else:
               Enum.sum(Enum.map(claimed, &DateTime.diff(&1.outcome_at, &1.inserted_at))) /
                 length(claimed)
           )
       }}
    end)
  end

  defp role_of(agents, id) do
    case Map.get(agents, id) do
      nil -> :unknown
      agent -> agent.role
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp within(items, {from, to}, at_fn) do
    Enum.filter(items, fn item ->
      case at_fn.(item) do
        nil -> false
        at -> DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt
      end
    end)
  end

  defp share([], _pred), do: nil
  defp share(items, pred), do: Enum.count(items, pred) / length(items)

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
