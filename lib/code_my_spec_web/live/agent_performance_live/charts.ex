defmodule CodeMySpecWeb.AgentPerformanceLive.Charts do
  @moduledoc """
  The performance page's summaries as chart data for its EChart hook.

  A dashboard summarizes: every story's stage times on one stacked bar chart
  and every wait on another, with what a card per story used to list carried
  as that story's tooltip lines (John, 2026-10-14).
  """

  alias CodeMySpec.AgentPerformance.Stage

  @per_page 10
  @holders [:user, :main_agent, :another_team]

  @doc "The released stories, narrowed by the page's filter."
  def stories(stories, reports, agents, filter) do
    Enum.filter(
      stories,
      &(Map.fetch!(reports, &1.id).cycle_time.released_at && story_matches?(&1, filter, agents))
    )
  end

  @doc "How many pages a bar chart's categories fill, at #{@per_page} a page."
  def page_count(%{"categories" => categories}),
    do: max(1, div(length(categories) + @per_page - 1, @per_page))

  @doc "One page of a bar chart: its categories, keys, details and every stack's data sliced alike."
  def page(chart, page) do
    slice = &Enum.slice(&1 || [], (page - 1) * @per_page, @per_page)

    chart
    |> Map.update("categories", [], slice)
    |> Map.update("details", [], slice)
    |> Map.replace_lazy("keys", slice)
    |> Map.update("stacks", [], fn stacks -> Enum.map(stacks, &Map.update!(&1, "data", slice)) end)
  end

  @doc "One stacked bar per story, longest first: each stage's active hours, then its waiting hours."
  def stages(stories, reports) do
    rows =
      stories
      |> Enum.map(&{&1, Map.fetch!(reports, &1.id)})
      |> Enum.sort_by(fn {_story, r} -> story_seconds(r.cycle_time) end, :desc)

    stage_stacks =
      Enum.map(Stage.names(), fn stage ->
        stack(to_string(stage), rows, fn {_story, r} -> Map.get(r.cycle_time.stages, stage) end)
      end)

    waiting = stack("waiting", rows, fn {_story, r} -> blocked_seconds(r.cycle_time.blocked) end)

    %{
      "kind" => "bars",
      "unit" => "h",
      "categories" => Enum.map(rows, fn {story, _r} -> story.title end),
      "stacks" => stage_stacks ++ [waiting],
      "details" => Enum.map(rows, fn {_story, r} -> story_details(r) end)
    }
  end

  @doc "One bar per holder: resolved, lapsed and still-open waiting hours."
  def blocked(stories, reports, open_waits) do
    spans = Enum.flat_map(stories, &Map.fetch!(reports, &1.id).cycle_time.blocked)
    {resolved, lapsed} = Enum.split_with(spans, & &1.resolved?)

    %{
      "kind" => "bars",
      "unit" => "h",
      "categories" => Enum.map(@holders, &waiting_on_label/1),
      "stacks" => [
        holder_stack("resolved", resolved),
        holder_stack("lapsed", lapsed),
        holder_stack("open now", open_waits)
      ],
      "details" =>
        Enum.map(@holders, fn holder ->
          holder_details(Enum.filter(spans ++ open_waits, &(&1.waiting_on == holder)))
        end)
    }
  end

  @doc """
  Two bars per team: its QA attempts stacked by outcome, and the stories it
  promoted. Busiest first, by attempts plus promotions.
  """
  def teams(rates, promoted, qa_by_copy, working_copies) do
    copies =
      [Map.keys(rates), Map.keys(promoted), Map.keys(qa_by_copy)]
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&(-(Map.get(promoted, &1, 0) + attempts(qa_by_copy, &1))))

    outcome = fn status -> Enum.map(copies, &get_in(qa_by_copy, [&1, status])) end

    %{
      "kind" => "bars",
      "unit" => "",
      "keys" => copies,
      "categories" => Enum.map(copies, &team_name(working_copies, &1)),
      "stacks" => [
        %{"name" => "QA pass", "stack" => "qa", "color" => "#22c55e", "data" => outcome.(:pass)},
        %{
          "name" => "QA partial",
          "stack" => "qa",
          "color" => "#f59e0b",
          "data" => outcome.(:partial)
        },
        %{"name" => "QA fail", "stack" => "qa", "color" => "#ef4444", "data" => outcome.(:fail)},
        %{
          "name" => "promoted",
          "stack" => "promoted",
          "color" => "#3b82f6",
          "data" => Enum.map(copies, &Map.get(promoted, &1, 0))
        }
      ],
      "details" =>
        Enum.map(copies, fn copy ->
          [
            "First-pass rate: #{percent(Map.get(rates, copy))}",
            "QA attempts: #{attempts(qa_by_copy, copy)}",
            "Promoted: #{Map.get(promoted, copy, 0)}"
          ]
        end)
    }
  end

  @doc """
  One bar per agent that made tool calls or had a turn fail: its tool-call
  failure rate, highest first, with its failing tools and failed-turn causes
  on hover.
  """
  def agents(rows, agents, filter) do
    copies = Map.new(agents, &{&1.id, &1.working_copy_id})

    rows =
      rows
      |> Enum.filter(
        &((&1.tool_failures.total_calls > 0 or &1.reliability != []) and
            agent_matches?(&1, filter, copies))
      )
      |> Enum.sort_by(&(-(&1.tool_failures.failure_rate || 0)))

    %{
      "kind" => "bars",
      "unit" => "%",
      "keys" => Enum.map(rows, & &1.agent_id),
      "categories" =>
        Enum.map(rows, &"#{&1.role} · #{&1.provider} · #{String.slice(&1.agent_id, 0, 8)}"),
      "stacks" => [
        %{
          "name" => "tool failure rate",
          "color" => "#ef4444",
          "data" => Enum.map(rows, &rate_percent(&1.tool_failures.failure_rate))
        }
      ],
      "details" => Enum.map(rows, &agent_details/1)
    }
  end

  defp agent_matches?(row, filter, copies) do
    Map.get(filter, :agent_id, row.agent_id) == row.agent_id and
      Map.get(filter, :working_copy_id, Map.get(copies, row.agent_id)) ==
        Map.get(copies, row.agent_id)
  end

  defp agent_details(row) do
    tools =
      row.tool_failures.by_tool
      |> Enum.sort_by(fn {_tool, count} -> -count end)
      |> Enum.take(5)
      |> Enum.map(fn {tool, count} -> "  #{tool}: #{count} failed" end)

    ["#{row.tool_failures.total_calls} tool calls, #{row.tool_failures.failed_calls} failed"] ++
      tools ++ Enum.map(row.reliability, &"Failed turn: #{&1.cause}")
  end

  defp rate_percent(nil), do: 0
  defp rate_percent(rate), do: Float.round(rate * 100, 1)

  def team_name(working_copies, id) do
    case Enum.find(working_copies, &(&1.id == id)) do
      nil -> String.slice(id, 0, 8)
      copy -> CodeMySpec.WorkingCopies.display_name(copy)
    end
  end

  def percent(nil), do: "not yet measured"
  def percent(rate), do: "#{round(rate * 100)}%"

  defp attempts(qa_by_copy, copy),
    do: qa_by_copy |> Map.get(copy, %{}) |> Map.values() |> Enum.sum()

  defp story_seconds(cycle_time) do
    stage_seconds = cycle_time.stages |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.sum()
    stage_seconds + blocked_seconds(cycle_time.blocked)
  end

  @doc """
  Messages to agents by kind -- messages, restarts and each system notice --
  summed over the agents the filter leaves (a story filter keeps the agents
  holding it).
  """
  def message_kinds(by_agent, agents, filter) do
    agents
    |> Enum.filter(fn agent ->
      Enum.all?(filter, fn
        {:story_id, id} -> agent.story_id == id
        {:working_copy_id, id} -> agent.working_copy_id == id
        {:agent_id, id} -> agent.id == id
      end)
    end)
    |> Enum.map(&Map.get(by_agent, &1.id, %{}))
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _kind, a, b -> a + b end))
  end

  @doc "Tool failure rate by role and provider this week, with replies, calls and tokens on hover."
  def roles(rows) do
    rows = Enum.sort_by(rows, &(-ratio(&1.failed, &1.calls)))

    %{
      "kind" => "bars",
      "unit" => "%",
      "categories" => Enum.map(rows, &"#{&1.role} · #{&1.provider || "unknown"}"),
      "stacks" => [
        %{
          "name" => "tool failure rate",
          "color" => "#ef4444",
          "data" => Enum.map(rows, &Float.round(ratio(&1.failed, &1.calls) * 100, 1))
        }
      ],
      "details" =>
        Enum.map(rows, fn row ->
          [
            "#{row.replies} replies, #{row.calls} tool calls, #{row.failed} failed",
            "#{row.failed_turns} failed turn(s)",
            "#{row.tokens} tokens"
          ]
        end)
    }
  end

  @doc "Tap-outs by the role that raised them this week, stacked by how each ended."
  def tap_outs(by_role) do
    statuses = [
      {"approved", "#22c55e"},
      {"denied", "#64748b"},
      {"expired", "#ef4444"},
      {"pending", "#f59e0b"}
    ]

    status_bars(by_role, statuses, fn _role, counts ->
      decided = Enum.sum(for s <- ["approved", "denied", "expired"], do: Map.get(counts, s, 0))
      ["Expired undecided: #{percent(ratio(Map.get(counts, "expired", 0), decided))} of decided"]
    end)
  end

  @doc "How long each role's questions waited for an answer this week, in minutes."
  def questions(by_role) do
    rows = Enum.sort_by(by_role, fn {_role, q} -> -(q.median_minutes || 0) end)

    %{
      "kind" => "bars",
      "unit" => "m",
      "categories" => Enum.map(rows, fn {role, _q} -> to_string(role) end),
      "stacks" => [
        %{
          "name" => "median wait",
          "color" => "#2f6f8f",
          "data" => Enum.map(rows, fn {_role, q} -> round_or_nil(q.median_minutes) end)
        }
      ],
      "details" =>
        Enum.map(rows, fn {_role, q} ->
          counts = Enum.map_join(q.statuses, ", ", fn {status, n} -> "#{n} #{status}" end)
          ["#{counts}", "Average wait: #{duration_minutes(q.average_minutes)}"]
        end)
    }
  end

  @doc "Offers by kind this week, stacked by outcome, with claim rate and time to claim on hover."
  def offer_kinds(by_kind) do
    statuses = [
      {:claimed, "#22c55e"},
      {:ignored, "#f59e0b"},
      {:declined, "#ef4444"},
      {:superseded, "#94a3b8"},
      {:expired, "#64748b"},
      {:open, "#3b82f6"}
    ]

    by_kind
    |> Map.new(fn {kind, k} -> {kind, k.statuses} end)
    |> status_bars(statuses, fn kind, counts ->
      settled = Enum.sum(for s <- [:claimed, :ignored, :declined], do: Map.get(counts, s, 0))
      seconds = by_kind |> Map.get(kind, %{}) |> Map.get(:average_seconds_to_claim)

      [
        "Claim rate: #{percent(ratio(Map.get(counts, :claimed, 0), settled))} of settled",
        "Average time to claim: #{if seconds, do: duration(round(seconds)), else: "none claimed"}"
      ]
    end)
  end

  defp status_bars(by_group, statuses, details_fn) do
    rows = Enum.sort_by(by_group, fn {_group, counts} -> -Enum.sum(Map.values(counts)) end)

    %{
      "kind" => "bars",
      "unit" => "",
      "categories" => Enum.map(rows, fn {group, _counts} -> to_string(group) end),
      "stacks" =>
        Enum.map(statuses, fn {status, color} ->
          %{
            "name" => to_string(status),
            "color" => color,
            "data" => Enum.map(rows, fn {_group, counts} -> Map.get(counts, status) end)
          }
        end),
      "details" => Enum.map(rows, fn {group, counts} -> details_fn.(group, counts) end)
    }
  end

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, whole), do: part / whole

  defp round_or_nil(nil), do: nil
  defp round_or_nil(value), do: round(value)

  defp duration_minutes(nil), do: "none answered"
  defp duration_minutes(minutes), do: duration(round(minutes * 60))

  def bars_height(%{"categories" => categories}), do: max(200, length(categories) * 28 + 80)

  @doc "A span of seconds as hours and minutes: `25m`, `1h`, `3h 20m`."
  def duration(nil), do: "unknown"
  def duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  def duration(seconds) do
    case {div(seconds, 3600), div(rem(seconds, 3600), 60)} do
      {h, 0} -> "#{h}h"
      {h, m} -> "#{h}h #{m}m"
    end
  end

  def waiting_on_label(:another_team), do: "another team"
  def waiting_on_label(:main_agent), do: "the main agent"
  def waiting_on_label(:user), do: "the user"

  def cause_label(:tap_out), do: "tap-out"
  def cause_label(cause), do: to_string(cause)

  defp story_matches?(story, filter, agents) do
    Enum.all?(filter, fn
      {:story_id, id} -> story.id == id
      {:working_copy_id, id} -> story.working_copy_id == id
      {:agent_id, id} -> Enum.any?(agents, &(&1.id == id and &1.story_id == story.id))
    end)
  end

  defp stack(name, rows, seconds_fn),
    do: %{"name" => name, "data" => Enum.map(rows, &hours(seconds_fn.(&1)))}

  defp holder_stack(name, spans) do
    by_holder = Enum.group_by(spans, & &1.waiting_on)
    data = Enum.map(@holders, &hours(blocked_seconds(Map.get(by_holder, &1, []))))
    %{"name" => name, "data" => data}
  end

  defp holder_details(spans) do
    spans
    |> Enum.group_by(& &1.cause)
    |> Enum.map(fn {cause, group} ->
      "#{cause_label(cause)}: #{duration(blocked_seconds(group))} over #{length(group)} wait(s)"
    end)
    |> Enum.sort()
  end

  defp story_details(report) do
    Enum.concat([
      [cycle_line(report.cycle_time)],
      unknown_stage_lines(report.cycle_time.stages),
      qa_lines(report.qa_rounds),
      Enum.map(report.cycle_time.blocked, &wait_line/1),
      intervention_lines(report.interventions),
      token_lines(report.tokens)
    ])
  end

  defp unknown_stage_lines(stages) do
    case Enum.reject(Stage.names(), &Map.get(stages, &1)) do
      [] -> []
      unknown -> ["Unknown (no task matched): #{Enum.join(unknown, ", ")}"]
    end
  end

  defp cycle_line(%{status: :in_flight}), do: "Still running"
  defp cycle_line(cycle_time), do: "Total: #{duration(cycle_time.total_seconds)}"

  defp qa_lines(%{measured?: false}), do: ["QA: not yet measured (no QA attempt)"]

  defp qa_lines(qa) do
    first = if qa.first_time_pass?, do: "first-time pass", else: "no first-time pass"
    ["QA: #{qa.rounds} round(s), #{first}" | Enum.map(qa.findings, &"  found: #{&1}")]
  end

  defp wait_line(span) do
    lapsed = if span.resolved?, do: "", else: " (lapsed, still unresolved)"

    "Waited on #{waiting_on_label(span.waiting_on)} (#{cause_label(span.cause)}): " <>
      duration(span.seconds) <> lapsed
  end

  defp intervention_lines([]), do: []

  defp intervention_lines(interventions) do
    [
      "#{length(interventions)} intervention(s)"
      | Enum.map(interventions, &"  #{&1.kind}: #{&1.reason}")
    ]
  end

  defp token_lines(%{total: :unknown}), do: []

  defp token_lines(tokens) do
    providers =
      Enum.map_join(tokens.by_provider, ", ", fn {provider, total} -> "#{provider}: #{total}" end)

    ["#{tokens.total} tokens (#{providers})"]
  end

  defp blocked_seconds(spans), do: spans |> Enum.map(& &1.seconds) |> Enum.sum()

  # Unknown stays unknown: no task matched the stage, which is not zero time.
  defp hours(nil), do: nil
  defp hours(seconds), do: Float.round(seconds / 3600, 2)
end
