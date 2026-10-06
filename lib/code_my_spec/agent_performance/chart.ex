defmodule CodeMySpec.AgentPerformance.Chart do
  @moduledoc """
  The performance page's time-series chart: token spend, nudges, QA
  first-pass rate and failed turns, bucketed hourly over the last 7 days,
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
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @range_days 7
  @bucket_seconds 3600
  @bucket_count @range_days * 24

  @type filter :: %{optional(:working_copy_id) => Ecto.UUID.t(), optional(:story_id) => integer()}
  @type detail :: %{tokens_total: non_neg_integer() | :unknown, nudges: non_neg_integer()}

  @doc "The chart option this page hands its EChart hook, as a plain map ready for `Jason.encode!/1`."
  @spec option(Scope.t(), filter()) :: map()
  def option(%Scope{} = scope, filter \\ %{}) do
    until = DateTime.utc_now()
    since = DateTime.add(until, -@range_days * 24 * 3600, :second)
    buckets = bucket_starts(since)

    %{
      "range_days" => @range_days,
      "bucket_interval" => "hour",
      "bucket_count" => @bucket_count,
      "categories" => Enum.map(buckets, &DateTime.to_iso8601/1),
      "series" => [
        %{
          "name" => "token_spend",
          "type" => "line",
          "data" => bucket_sums(buckets, turns_for(scope, filter, since, until), & &1.inserted_at, &token_total/1)
        },
        %{
          "name" => "nudges",
          "type" => "line",
          "data" => bucket_sums(buckets, nudges_for(scope, filter, since, until), & &1.at, fn _ -> 1 end)
        },
        %{
          "name" => "qa_first_pass_rate",
          "type" => "line",
          "data" => bucket_rates(buckets, first_attempts_for(scope, filter, since, until))
        },
        %{
          "name" => "failed_turns",
          "type" => "line",
          "data" => bucket_sums(buckets, failures_for(scope, filter, since, until), & &1.at, fn _ -> 1 end)
        }
      ],
      "events" => events_for(scope, filter, since, until)
    }
  end

  @doc "Tokens spent and nudges served, summarized rather than listed row by row (criterion 2034)."
  @spec detail(Scope.t(), filter()) :: detail()
  def detail(%Scope{} = scope, filter \\ %{}) do
    %{
      tokens_total: tokens_total(scope, filter),
      nudges: scope |> Interventions.for_scope(filter) |> Enum.count(&(&1.kind == :nudge))
    }
  end

  defp tokens_total(scope, filter) do
    turns =
      AgentTurn
      |> where([t], t.account_id == ^scope.active_account_id)
      |> apply_turn_filter(filter)
      |> Repo.all()

    case Enum.filter(turns, &(&1.input_tokens || &1.output_tokens)) do
      [] -> :unknown
      with_usage -> Enum.reduce(with_usage, 0, &(&2 + (&1.input_tokens || 0) + (&1.output_tokens || 0)))
    end
  end

  defp turns_for(scope, filter, since, until) do
    AgentTurn
    |> where([t], t.account_id == ^scope.active_account_id)
    |> where([t], t.inserted_at >= ^since and t.inserted_at <= ^until)
    |> apply_turn_filter(filter)
    |> Repo.all()
  end

  defp apply_turn_filter(query, %{story_id: id}) when not is_nil(id) do
    where(query, [t], t.story_id == ^id)
  end

  defp apply_turn_filter(query, %{working_copy_id: id}) when not is_nil(id) do
    query
    |> join(:inner, [t], a in Agent, on: a.id == t.agent_id)
    |> where([t, a], a.working_copy_id == ^id)
  end

  defp apply_turn_filter(query, _filter), do: query

  defp token_total(%AgentTurn{input_tokens: i, output_tokens: o}), do: (i || 0) + (o || 0)

  defp nudges_for(scope, filter, since, until) do
    scope
    |> Interventions.for_scope(filter)
    |> Enum.filter(&(&1.kind == :nudge and in_window?(&1.at, since, until)))
  end

  defp failures_for(scope, filter, since, until) do
    scope
    |> Agents.list_agents()
    |> filter_agents(filter)
    |> Enum.filter(&match?(%{provider_refused_at: %DateTime{}}, &1))
    |> Enum.map(&%{at: &1.provider_refused_at, cause: &1.provider_refusal})
    |> Enum.filter(&in_window?(&1.at, since, until))
  end

  defp filter_agents(agents, %{story_id: id}) when not is_nil(id), do: Enum.filter(agents, &(&1.story_id == id))

  defp filter_agents(agents, %{working_copy_id: id}) when not is_nil(id),
    do: Enum.filter(agents, &(&1.working_copy_id == id))

  defp filter_agents(agents, _filter), do: agents

  # One QA attempt per story -- its first, win or lose -- the same "first
  # attempt" QaRounds.team_first_pass_rate/3 counts a team's rate from.
  defp first_attempts_for(scope, filter, since, until) do
    agent_copies = scope |> Agents.list_agents() |> Map.new(&{&1.id, &1.working_copy_id})

    scope
    |> Qa.list_project_attempts(include_older: true, include_invalidated: true)
    |> Enum.group_by(& &1.story_id)
    |> Enum.map(fn {_story_id, attempts} -> Enum.min_by(attempts, & &1.submitted_at, DateTime) end)
    |> Enum.filter(
      &(matches_attempt?(&1, filter, agent_copies) and in_window?(&1.submitted_at, since, until))
    )
  end

  defp matches_attempt?(attempt, %{story_id: id}, _copies) when not is_nil(id), do: attempt.story_id == id

  defp matches_attempt?(attempt, %{working_copy_id: id}, copies) when not is_nil(id),
    do: Map.get(copies, attempt.agent_id) == id

  defp matches_attempt?(_attempt, _filter, _copies), do: true

  defp events_for(scope, filter, since, until) do
    scope
    |> list_stories()
    |> filter_stories(filter)
    |> Enum.flat_map(fn story ->
      cycle = CycleTime.story(scope, story)

      []
      |> maybe_event("story_start", cycle.released_at, story, since, until)
      |> maybe_event("promotion", cycle.promoted_at, story, since, until)
    end)
    |> Enum.sort_by(& &1["at"])
  end

  defp filter_stories(stories, %{story_id: id}) when not is_nil(id), do: Enum.filter(stories, &(&1.id == id))

  defp filter_stories(stories, %{working_copy_id: id}) when not is_nil(id),
    do: Enum.filter(stories, &(&1.working_copy_id == id))

  defp filter_stories(stories, _filter), do: stories

  defp maybe_event(acc, _type, nil, _story, _since, _until), do: acc

  defp maybe_event(acc, type, at, story, since, until) do
    if in_window?(at, since, until) do
      [%{"type" => type, "at" => DateTime.to_iso8601(at), "story_id" => story.id, "title" => story.title} | acc]
    else
      acc
    end
  end

  defp in_window?(nil, _since, _until), do: false

  defp in_window?(at, since, until),
    do: DateTime.compare(at, since) != :lt and DateTime.compare(at, until) != :gt

  defp bucket_starts(since) do
    start = %{since | minute: 0, second: 0, microsecond: {0, 0}}
    for i <- 0..(@bucket_count - 1), do: DateTime.add(start, i * @bucket_seconds, :second)
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

  defp bucket_rates(buckets, attempts) do
    groups =
      attempts
      |> Enum.group_by(&bucket_index(buckets, &1.submitted_at))
      |> Map.delete(nil)

    Enum.with_index(buckets)
    |> Enum.map(fn {_bucket, idx} ->
      case Map.get(groups, idx) do
        nil -> nil
        list -> Enum.count(list, &(&1.status == :pass)) / length(list)
      end
    end)
  end

  defp list_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
    end
  end
end
