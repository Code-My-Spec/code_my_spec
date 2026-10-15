defmodule CodeMySpec.AgentPerformance.Chart do
  @moduledoc """
  The performance page's time-series charts: token spend, messages and failed
  turns, and beside them offer acceptance and tool-call failure rate --
  bucketed hourly over the last 7 days,
  with story starts and promotions carried as events rather than chart
  lines (criteria 2029-2031).

  Narrowed to one working copy or one story by `filter` (criteria
  2032-2033); an empty filter is the project as a whole. The chart option
  this builds is handed whole to the page's EChart hook as JSON -- nothing
  here is Elixir-rendered.
  """

  import Ecto.Query

  alias CodeMySpec.AgentPerformance.AgentTurn
  alias CodeMySpec.AgentPerformance.CycleTime
  alias CodeMySpec.AgentPerformance.Interventions
  alias CodeMySpec.AgentPerformance.OfferHealth
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @range_days 7
  @bucket_seconds 3600
  @bucket_count @range_days * 24

  @type filter :: %{
          optional(:working_copy_id) => Ecto.UUID.t(),
          optional(:story_id) => integer(),
          optional(:agent_id) => Ecto.UUID.t()
        }
  @type detail :: %{tokens_total: non_neg_integer() | :unknown, messages: non_neg_integer()}

  @doc "The chart option this page hands its EChart hook, as a plain map ready for `Jason.encode!/1`."
  @spec option(Scope.t(), filter()) :: map()
  def option(%Scope{} = scope, filter \\ %{}) do
    until = DateTime.utc_now()
    buckets = bucket_starts(until)
    since = hd(buckets)

    %{
      "range_days" => @range_days,
      "bucket_interval" => "hour",
      "bucket_count" => @bucket_count,
      "categories" => Enum.map(buckets, &DateTime.to_iso8601/1),
      "series" => [
        %{
          "name" => "token_spend",
          "type" => "line",
          "y_axis" => "tokens",
          "data" =>
            bucket_sums(
              buckets,
              turns_for(scope, filter, since, until),
              & &1.inserted_at,
              &token_total/1
            )
        },
        %{
          "name" => "messages",
          "type" => "line",
          "y_axis" => "count",
          "data" =>
            bucket_sums(buckets, messages_for(scope, filter, since, until), & &1.at, fn _ -> 1 end)
        },
        %{
          "name" => "failed_turns",
          "type" => "line",
          "y_axis" => "count",
          "data" =>
            bucket_sums(buckets, failures_for(scope, filter, since, until), & &1.at, fn _ -> 1 end)
        }
      ],
      "events" => events_for(scope, filter, since, until)
    }
  end

  @doc """
  The rates chart: offer acceptance and tool-call failure rate, hourly over
  the same 7 days and narrowed by the same filter. Both are fractions, so they
  share one axis apart from the counts on `option/2`.
  """
  @spec rates_option(Scope.t(), filter()) :: map()
  def rates_option(%Scope{} = scope, filter \\ %{}) do
    until = DateTime.utc_now()
    buckets = bucket_starts(until)
    since = hd(buckets)

    %{
      "categories" => Enum.map(buckets, &DateTime.to_iso8601/1),
      "series" => [
        %{
          "name" => "offer_acceptance",
          "type" => "line",
          "y_axis" => "rate",
          "connectNulls" => true,
          "data" => bucket_rates(buckets, offer_outcomes_for(scope, filter, since))
        },
        %{
          "name" => "tool_failure_rate",
          "type" => "line",
          "y_axis" => "rate",
          "connectNulls" => true,
          "data" => bucket_rates(buckets, tool_results_for(scope, filter, since, until))
        }
      ],
      "events" => []
    }
  end

  @doc """
  QA attempts by outcome, narrowed like the chart: in total for the page's QA
  ring, and per working copy (through the agent that submitted each) for its
  teams chart. Every attempt counts, not only a story's first: an hourly
  first-pass rate was mostly empty hours, so QA is passed against failed
  rather than a line (John, 2026-10-14).
  """
  @spec qa_counts(Scope.t(), filter()) :: %{
          total: %{atom() => pos_integer()},
          by_copy: %{Ecto.UUID.t() => %{atom() => pos_integer()}}
        }
  def qa_counts(%Scope{} = scope, filter \\ %{}) do
    agent_copies = scope |> Agents.list_agents() |> Map.new(&{&1.id, &1.working_copy_id})

    attempts =
      scope
      |> Qa.list_project_attempts(include_older: true)
      |> Enum.filter(&matches_attempt?(&1, filter, agent_copies))

    by_copy =
      attempts
      |> Enum.group_by(&Map.get(agent_copies, &1.agent_id))
      |> Map.delete(nil)
      |> Map.new(fn {copy_id, group} -> {copy_id, Enum.frequencies_by(group, & &1.status)} end)

    %{total: Enum.frequencies_by(attempts, & &1.status), by_copy: by_copy}
  end

  @doc "Tokens spent and messages sent, summarized rather than listed row by row (criterion 2034)."
  @spec detail(Scope.t(), filter()) :: detail()
  def detail(%Scope{} = scope, filter \\ %{}) do
    %{
      tokens_total: tokens_total(scope, filter),
      messages: scope |> Interventions.for_scope(filter) |> Enum.count(&(&1.kind == :message))
    }
  end

  defp tokens_total(scope, filter) do
    turns =
      AgentTurn
      |> where([t], t.account_id == ^scope.active_account_id)
      |> apply_turn_filter(filter)
      |> Repo.all()

    case Enum.filter(turns, &(&1.input_tokens || &1.output_tokens)) do
      [] ->
        :unknown

      with_usage ->
        Enum.reduce(with_usage, 0, &(&2 + (&1.input_tokens || 0) + (&1.output_tokens || 0)))
    end
  end

  defp turns_for(scope, filter, since, until) do
    AgentTurn
    |> where([t], t.account_id == ^scope.active_account_id)
    |> where([t], t.inserted_at >= ^since and t.inserted_at <= ^until)
    |> apply_turn_filter(filter)
    |> Repo.all()
  end

  # Each narrowing key is applied in turn, so a filter naming more than one
  # narrows by all of them rather than whichever clause matched first. The page
  # offers agent alongside working copy and story, and picking an agent after
  # picking a copy must not silently drop the copy.
  defp apply_turn_filter(query, filter) do
    query
    |> filter_turns_by(:story_id, filter, fn q, id -> where(q, [t], t.story_id == ^id) end)
    |> filter_turns_by(:agent_id, filter, fn q, id -> where(q, [t], t.agent_id == ^id) end)
    |> filter_turns_by(:working_copy_id, filter, fn q, id ->
      q
      |> join(:inner, [t], a in Agent, on: a.id == t.agent_id)
      |> where([t, a], a.working_copy_id == ^id)
    end)
  end

  defp filter_turns_by(query, key, filter, fun) do
    case Map.get(filter, key) do
      nil -> query
      value -> fun.(query, value)
    end
  end

  defp token_total(%AgentTurn{input_tokens: i, output_tokens: o}), do: (i || 0) + (o || 0)

  defp messages_for(scope, filter, since, until) do
    scope
    |> Interventions.for_scope(filter)
    |> Enum.filter(&(&1.kind == :message and in_window?(&1.at, since, until)))
  end

  # Every "Your last turn failed" notice the harness sent. The agent row keeps
  # only its latest provider refusal, so charting that showed none at all
  # while 131 turns failed in a week (2026-10-14).
  defp failures_for(scope, filter, since, until) do
    Message
    |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
    |> where(
      [m, c],
      c.account_id == ^scope.active_account_id and c.project_id == ^scope.active_project_id and
        not is_nil(c.agent_id)
    )
    |> where([m], m.role == :operator and m.inserted_at >= ^since and m.inserted_at <= ^until)
    |> where([m], fragment("ltrim(?->0->>'text') LIKE 'Your last turn failed%'", m.content))
    |> narrow_to_agents(agent_ids_for(scope, filter))
    |> select([m], %{at: m.inserted_at})
    |> Repo.all()
  end

  defp filter_agents(agents, filter) do
    agents
    |> narrow(&(&1.story_id == &2), :story_id, filter)
    |> narrow(&(&1.id == &2), :agent_id, filter)
    |> narrow(&(&1.working_copy_id == &2), :working_copy_id, filter)
  end

  defp narrow(items, match?, key, filter) do
    case Map.get(filter, key) do
      nil -> items
      value -> Enum.filter(items, &match?.(&1, value))
    end
  end

  # The QA attempt is attributed by the agent that submitted it, so an agent
  # filter matches the attempt's own `agent_id`; a working-copy filter matches
  # the copy that agent is (or was) on.
  defp matches_attempt?(attempt, filter, copies) do
    matches_attempt_field?(attempt, :story_id, filter, &(&1.story_id == &2)) and
      matches_attempt_field?(attempt, :agent_id, filter, &(&1.agent_id == &2)) and
      matches_attempt_field?(attempt, :working_copy_id, filter, fn a, id ->
        Map.get(copies, a.agent_id) == id
      end)
  end

  defp matches_attempt_field?(attempt, key, filter, match?) do
    case Map.get(filter, key) do
      nil -> true
      value -> match?.(attempt, value)
    end
  end

  defp events_for(scope, filter, since, until) do
    # The project's tasks once, rather than `CycleTime.story/2`'s two listings
    # per story: that was the read that grew with the project and kept the
    # page's join past the socket timeout (issue 5d359bb3). The events are the
    # only thing on the chart that needs per-story work, so it is the only
    # place the tasks are worth reading up front.
    tasks = CycleTime.all_tasks(scope)

    scope
    |> list_stories()
    |> filter_stories(filter)
    |> Enum.flat_map(fn story ->
      cycle =
        CycleTime.story(scope, story, CycleTime.tasks_for(tasks, story.id, story.component_id))

      []
      |> maybe_event("story_start", cycle.released_at, story, since, until)
      |> maybe_event("promotion", cycle.promoted_at, story, since, until)
    end)
    |> Enum.sort_by(& &1["at"])
  end

  # Events belong to stories, so an agent filter narrows them to the story that
  # agent holds. An agent between stories holds none, and then no event is the
  # honest answer -- its own turns and failures still chart.
  defp filter_stories(stories, filter) do
    stories
    |> narrow(&(&1.id == &2), :story_id, filter)
    |> narrow(&(&1.working_copy_id == &2), :working_copy_id, filter)
    |> narrow_stories_by_agent(filter)
  end

  # The agent's own story, read from its row -- the story an agent holds is the
  # one its start/promotion events belong to. An agent holding none contributes
  # no events rather than every event.
  defp narrow_stories_by_agent(stories, %{agent_id: agent_id}) when not is_nil(agent_id) do
    case story_held_by(agent_id) do
      nil -> []
      story_id -> Enum.filter(stories, &(&1.id == story_id))
    end
  end

  defp narrow_stories_by_agent(stories, _filter), do: stories

  defp story_held_by(agent_id) do
    Agent |> where([a], a.id == ^agent_id) |> select([a], a.story_id) |> Repo.one()
  end

  defp maybe_event(acc, _type, nil, _story, _since, _until), do: acc

  defp maybe_event(acc, type, at, story, since, until) do
    if in_window?(at, since, until) do
      [
        %{
          "type" => type,
          "at" => DateTime.to_iso8601(at),
          "story_id" => story.id,
          "number" => story.number,
          "title" => story.title
        }
        | acc
      ]
    else
      acc
    end
  end

  defp in_window?(nil, _since, _until), do: false

  defp in_window?(at, since, until),
    do: DateTime.compare(at, since) != :lt and DateTime.compare(at, until) != :gt

  # The last bucket is the hour `until` falls in. Counted forward from 7 days
  # back, the current hour sat one past the end and nothing in it was charted.
  defp bucket_starts(until) do
    current = %{until | minute: 0, second: 0, microsecond: {0, 0}}

    for i <- (@bucket_count - 1)..0//-1,
        do: DateTime.add(current, -i * @bucket_seconds, :second)
  end

  defp bucket_index([first | _] = buckets, at) do
    idx = DateTime.diff(at, first) |> div(@bucket_seconds)
    if idx >= 0 and idx < length(buckets), do: idx
  end

  defp bucket_sums(buckets, items, time_fn, value_fn) do
    totals = List.duplicate(0, length(buckets))

    Enum.reduce(items, totals, fn item, acc ->
      case bucket_index(buckets, time_fn.(item)) do
        nil -> acc
        idx -> List.update_at(acc, idx, &(&1 + value_fn.(item)))
      end
    end)
  end

  # Tool results in the window. Tool calls run to hundreds an hour, so an
  # hourly failure rate has a denominator worth charting. A story filter
  # narrows to the agents holding that story, as the events do.
  defp tool_results_for(scope, filter, since, until) do
    Message
    |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
    |> where(
      [m, c],
      c.account_id == ^scope.active_account_id and c.project_id == ^scope.active_project_id and
        not is_nil(c.agent_id)
    )
    |> where([m], m.role == :tool and not is_nil(m.tool_call_id))
    |> where([m], m.inserted_at >= ^since and m.inserted_at <= ^until)
    |> narrow_to_agents(agent_ids_for(scope, filter))
    |> select([m], %{at: m.inserted_at, hit: m.tool_failed})
    |> Repo.all()
  end

  # Settled offers only -- claimed, ignored or declined -- counted the way
  # `OfferHealth` counts a claim rate. `failed` is "not claimed", so the
  # shared bucketing reads it back as the claim rate's complement.
  defp offer_outcomes_for(scope, filter, since) do
    agent_ids = agent_ids_for(scope, filter)

    scope
    |> Offers.list(since: since, limit: 100_000)
    |> Enum.filter(
      &(OfferHealth.counted?(&1) and &1.status in [:claimed, :ignored, :declined] and
          (is_nil(agent_ids) or &1.agent_id in agent_ids))
    )
    |> Enum.map(&%{at: &1.inserted_at, hit: &1.status == :claimed})
  end

  defp agent_ids_for(scope, filter) do
    if Enum.any?([:story_id, :agent_id, :working_copy_id], &Map.has_key?(filter, &1)),
      do: scope |> Agents.list_agents() |> filter_agents(filter) |> Enum.map(& &1.id)
  end

  defp narrow_to_agents(query, nil), do: query
  defp narrow_to_agents(query, ids), do: where(query, [m, c], c.agent_id in ^ids)

  defp bucket_rates(buckets, results) do
    groups = results |> Enum.group_by(&bucket_index(buckets, &1.at)) |> Map.delete(nil)

    for idx <- 0..(length(buckets) - 1) do
      case Map.get(groups, idx) do
        nil -> nil
        list -> Float.round(Enum.count(list, & &1.hit) / length(list), 4)
      end
    end
  end

  defp list_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
    end
  end
end
