defmodule CodeMySpec.AgentPerformance.Report do
  @moduledoc """
  The performance page as Markdown, for an agent to read and plan from.

  Same sections, same order and same numbers as the page -- what stands out,
  what to change first, activity by role, QA, time per story, blocked time,
  offers, messages, limits -- written as tables rather than drawn, because
  John hands this to agents to come up with improvement plans (2026-10-15).
  Narrowed by the page's filter.
  """

  alias CodeMySpec.AgentPerformance.Chart
  alias CodeMySpec.AgentPerformance.Page
  alias CodeMySpec.AgentPerformance.Scorecard
  alias CodeMySpec.AgentPerformance.Stage
  alias CodeMySpec.Users.Scope

  @top 15
  @order %{bad: 0, warn: 1, good: 2, none: 3}

  @doc "The report for this project, narrowed by `filter` (working copy, story, agent)."
  @spec markdown(Scope.t(), map()) :: String.t()
  def markdown(%Scope{} = scope, filter \\ %{}) do
    page = Page.load(scope)
    card = Scorecard.load(scope, filter)
    qa = Chart.qa_counts(scope, filter)
    agents = narrow(page.agents, filter)
    stories = stories(page, agents, filter)

    [
      header(scope, filter),
      standouts(card.kpis),
      changes(card.kpis),
      roles(card.roles, page.summary.agents, agents),
      qa_section(qa, page),
      time_per_story(stories, page.reports),
      blocked(stories, page.reports, card),
      offers(card.offer_kinds),
      messages(page.summary.message_kinds_by_agent, agents),
      limits()
    ]
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp header(scope, filter) do
    narrowed =
      case filter do
        empty when map_size(empty) == 0 -> "the whole project"
        filter -> Enum.map_join(filter, ", ", fn {k, v} -> "#{k} #{v}" end)
      end

    """
    # Agent performance

    Project #{scope.active_project_id}, #{narrowed}. Generated #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}.
    "This week" is the last 7 days; "last week" the 7 before.\
    """
  end

  # -- what stands out, what to change ---------------------------------------

  defp standouts(kpis) do
    rows =
      kpis
      |> Enum.sort_by(&Map.fetch!(@order, &1.severity))
      |> Enum.map(fn k ->
        [
          k.title,
          format(k.format, k.value),
          format(k.format, k.previous),
          to_string(k.severity),
          Enum.map_join(k.days, " ", &format(k.format, &1))
        ]
      end)

    "## What stands out\n\n" <>
      table(["Rate", "This week", "Last week", "Status", "Daily, oldest first"], rows)
  end

  defp changes(kpis) do
    needing =
      kpis
      |> Enum.filter(&(&1.severity in [:bad, :warn]))
      |> Enum.sort_by(&Map.fetch!(@order, &1.severity))

    body =
      case needing do
        [] ->
          "Nothing is past its threshold or worse than last week."

        needing ->
          needing
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {k, i} ->
            "#{i}. **#{k.title}: #{format(k.format, k.value)}** (#{k.severity}). #{k.change}"
          end)
      end

    "## What I'd change first\n\n" <> body
  end

  # -- activity by role and agent ------------------------------------------------

  defp roles(roles, agent_rows, agents) do
    by_role =
      Enum.map(roles, fn r ->
        [
          "#{r.role} · #{r.provider || "unknown"}",
          r.replies,
          r.calls,
          r.failed,
          percent(ratio(r.failed, r.calls)),
          r.failed_turns,
          r.tokens
        ]
      end)

    ids = MapSet.new(agents, & &1.id)

    by_agent =
      agent_rows
      |> Enum.filter(&(MapSet.member?(ids, &1.agent_id) and &1.tool_failures.total_calls > 0))
      |> Enum.sort_by(&(-(&1.tool_failures.failure_rate || 0)))
      |> Enum.take(@top)
      |> Enum.map(fn a ->
        tools =
          a.tool_failures.by_tool
          |> Enum.sort_by(fn {_tool, n} -> -n end)
          |> Enum.take(3)
          |> Enum.map_join(", ", fn {tool, n} -> "#{tool} #{n}" end)

        [
          "#{a.role} · #{a.provider} · #{String.slice(a.agent_id, 0, 8)}",
          a.tool_failures.total_calls,
          percent(a.tool_failures.failure_rate),
          tools,
          Enum.map_join(a.reliability, "; ", & &1.cause)
        ]
      end)

    """
    ## Activity by role

    This week, by role and provider.

    #{table(["Role · provider", "Replies", "Tool calls", "Failed", "Failure rate", "Failed turns", "Tokens"], by_role)}

    ### Agents with the highest tool failure rate (all time, top #{@top})

    #{table(["Agent", "Tool calls", "Failure rate", "Most-failing tools", "Last refusal"], by_agent)}\
    """
  end

  # -- QA -------------------------------------------------------------------------

  defp qa_section(qa, page) do
    totals = Enum.map_join(qa.total, ", ", fn {status, n} -> "#{n} #{status}" end)

    copies =
      [Map.keys(page.teams), Map.keys(page.summary.throughput_by_team), Map.keys(qa.by_copy)]
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    teams =
      copies
      |> Enum.map(fn copy ->
        counts = Map.get(qa.by_copy, copy, %{})
        promoted = Map.get(page.summary.throughput_by_team, copy, 0)

        {Enum.sum(Map.values(counts)) + promoted,
         [
           String.slice(copy, 0, 8),
           Map.get(counts, :pass, 0),
           Map.get(counts, :partial, 0),
           Map.get(counts, :fail, 0),
           promoted,
           percent(Map.get(page.teams, copy))
         ]}
      end)
      |> Enum.sort_by(&(-elem(&1, 0)))
      |> Enum.map(&elem(&1, 1))

    """
    ## QA

    QA attempts, all time: #{if totals == "", do: "none", else: totals}.

    #{table(["Team (copy)", "Pass", "Partial", "Fail", "Promoted", "First-pass rate"], teams)}\
    """
  end

  # -- time per story ----------------------------------------------------------------

  defp time_per_story(stories, reports) do
    rows =
      stories
      |> Enum.map(&{&1, Map.fetch!(reports, &1.id)})
      |> Enum.sort_by(fn {_s, r} -> -story_seconds(r.cycle_time) end)
      |> Enum.take(@top)
      |> Enum.map(fn {story, r} ->
        stages = Enum.map(Stage.names(), &hours(Map.get(r.cycle_time.stages, &1)))

        [
          "##{story.number} #{story.title}",
          if(r.cycle_time.status == :in_flight,
            do: "running",
            else: hours(r.cycle_time.total_seconds)
          )
        ] ++
          stages ++
          [
            hours(blocked_seconds(r.cycle_time.blocked)),
            qa_text(r.qa_rounds),
            length(r.interventions),
            tokens_text(r.tokens)
          ]
      end)

    headers =
      ["Story", "Total"] ++
        Enum.map(Stage.names(), &to_string/1) ++ ["Waiting", "QA", "Messages", "Tokens"]

    """
    ## Time per story

    The #{@top} longest released stories. Stage times are active hours; stages can overlap, so they may add up to more than the total. Blank means no task matched the stage.

    #{table(headers, rows)}\
    """
  end

  defp qa_text(%{measured?: false}), do: "none yet"

  defp qa_text(qa) do
    "#{qa.rounds} round(s), #{if qa.first_time_pass?, do: "first-time pass", else: "no first-time pass"}"
  end

  defp tokens_text(%{total: :unknown}), do: ""
  defp tokens_text(%{total: total}), do: "#{total}"

  # -- blocked time -----------------------------------------------------------------

  defp blocked(stories, reports, card) do
    spans = Enum.flat_map(stories, &Map.fetch!(reports, &1.id).cycle_time.blocked)

    holders =
      spans
      |> Enum.group_by(& &1.waiting_on)
      |> Enum.map(fn {holder, group} ->
        {resolved, lapsed} = Enum.split_with(group, & &1.resolved?)
        [holder, hours(blocked_seconds(resolved)), hours(blocked_seconds(lapsed)), length(group)]
      end)

    tap_outs =
      Enum.map(card.tap_outs, fn {role, counts} ->
        [role | Enum.map(~w(approved denied expired pending), &Map.get(counts, &1, 0))]
      end)

    questions =
      Enum.map(card.questions, fn {role, q} ->
        [
          role,
          Enum.map_join(q.statuses, ", ", fn {s, n} -> "#{n} #{s}" end),
          minutes(q.median_minutes),
          minutes(q.average_minutes)
        ]
      end)

    """
    ## Blocked time

    ### Hours waiting on a person, by who held it (released stories)

    #{table(["Waiting on", "Resolved", "Lapsed undecided", "Waits"], holders)}

    ### Tap-outs this week, by role

    #{table(["Role", "Approved", "Denied", "Expired", "Pending"], tap_outs)}

    ### Questions this week, by who asked

    #{table(["Role", "Outcomes", "Median wait", "Average wait"], questions)}\
    """
  end

  # -- offers and messages -----------------------------------------------------------

  defp offers(by_kind) do
    rows =
      by_kind
      |> Enum.sort_by(fn {_kind, k} -> -Enum.sum(Map.values(k.statuses)) end)
      |> Enum.map(fn {kind, k} ->
        s = k.statuses
        settled = Enum.sum(for st <- [:claimed, :ignored, :declined], do: Map.get(s, st, 0))

        [kind] ++
          Enum.map([:claimed, :ignored, :declined, :superseded, :expired], &Map.get(s, &1, 0)) ++
          [
            percent(ratio(Map.get(s, :claimed, 0), settled)),
            if(k.average_seconds_to_claim,
              do: minutes(k.average_seconds_to_claim / 60),
              else: ""
            )
          ]
      end)

    """
    ## Offers by kind this week

    "Ignored" over-counts: an earlier trace found most of them claimed another way.

    #{table(["Kind", "Claimed", "Ignored", "Declined", "Superseded", "Expired", "Claim rate", "Avg time to claim"], rows)}\
    """
  end

  defp messages(by_agent, agents) do
    totals =
      agents
      |> Enum.map(&Map.get(by_agent, &1.id, %{}))
      |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _k, a, b -> a + b end))
      |> Enum.sort_by(fn {_kind, n} -> -n end)
      |> Enum.map(fn {kind, n} -> [kind, n] end)

    "## Messages to agents by kind (all time)\n\n" <> table(["Kind", "Messages"], totals)
  end

  defp limits do
    """
    ## Limits of this report

    - Message kinds are read from each message's opening text: senders are not recorded yet, so a message from John and one from main look the same.
    - Token use is recorded from 2026-10-14; earlier turns have none.
    - A story's messages are counted against the story its agent holds now.
    - "Ignored" offers over-count.\
    """
  end

  # -- narrowing ---------------------------------------------------------------------

  defp narrow(agents, filter) do
    Enum.filter(agents, fn agent ->
      Enum.all?(filter, fn
        {:story_id, id} -> agent.story_id == id
        {:working_copy_id, id} -> agent.working_copy_id == id
        {:agent_id, id} -> agent.id == id
        _other -> true
      end)
    end)
  end

  defp stories(page, agents, filter) do
    held = MapSet.new(agents, & &1.story_id)

    Enum.filter(page.stories, fn story ->
      Map.fetch!(page.reports, story.id).cycle_time.released_at &&
        Enum.all?(filter, fn
          {:story_id, id} -> story.id == id
          {:working_copy_id, id} -> story.working_copy_id == id
          {:agent_id, _id} -> MapSet.member?(held, story.id)
          _other -> true
        end)
    end)
  end

  # -- formatting --------------------------------------------------------------------

  defp table(_headers, []), do: "None."

  defp table(headers, rows) do
    line = fn cells -> "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |" end

    Enum.join(
      [line.(headers), line.(Enum.map(headers, fn _ -> "---" end)) | Enum.map(rows, line)],
      "\n"
    )
  end

  defp cell(nil), do: ""
  defp cell(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp cell(value),
    do: value |> to_string() |> String.replace("|", "/") |> String.replace("\n", " ")

  defp format(_format, nil), do: "–"
  defp format(:percent, v), do: percent(v)
  defp format(:minutes, v), do: minutes(v)
  defp format(:count, v), do: "#{v}"
  defp format(:number, v), do: :erlang.float_to_binary(v * 1.0, decimals: 1)
  defp format(:tokens, v), do: "#{round(v)}"

  defp percent(nil), do: "–"
  defp percent(v), do: "#{round(v * 100)}%"

  defp minutes(nil), do: "–"
  defp minutes(v) when v < 60, do: "#{round(v)}m"
  defp minutes(v), do: "#{div(round(v), 60)}h #{rem(round(v), 60)}m"

  defp hours(nil), do: ""
  defp hours(seconds), do: "#{Float.round(seconds / 3600, 1)}h"

  defp ratio(_part, 0), do: nil
  defp ratio(part, whole), do: part / whole

  defp story_seconds(cycle_time) do
    (cycle_time.stages |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.sum()) +
      blocked_seconds(cycle_time.blocked)
  end

  defp blocked_seconds(spans), do: spans |> Enum.map(& &1.seconds) |> Enum.sum()
end
