defmodule CodeMySpecWeb.AgentPerformanceLive.Scorecard do
  @moduledoc """
  The performance page's headline layer: each rate this week with its change
  from last week, a sparkline of the week's days and a severity, then what to
  change first for the ones that need it -- the scorecard's "What stands out"
  and "What I'd change first", drawn rather than listed.
  """
  use CodeMySpecWeb, :html

  @order %{bad: 0, warn: 1, good: 2, none: 3}

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

  attr :kpis, :list, required: true

  def standouts(assigns) do
    assigns = assign(assigns, :kpis, Enum.sort_by(assigns.kpis, &Map.fetch!(@order, &1.severity)))

    ~H"""
    <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <a
        :for={kpi <- @kpis}
        href={"#section-#{kpi.section}"}
        data-test="kpi"
        data-kpi={kpi.key}
        data-severity={kpi.severity}
        class={[
          "flex flex-col gap-1 rounded-box border border-base-300 border-l-4 bg-base-100 p-3 hover:bg-base-200",
          severity_border(kpi.severity)
        ]}
      >
        <span class="text-xs uppercase tracking-wide text-base-content/60">{kpi.title}</span>
        <div class="flex items-end justify-between gap-3">
          <span class="text-2xl font-semibold tabular-nums">{format(kpi.format, kpi.value)}</span>
          <.sparkline values={kpi.days} severity={kpi.severity} />
        </div>
        <span class={["text-xs tabular-nums", delta_class(kpi)]}>{delta_text(kpi)}</span>
      </a>
    </div>
    """
  end

  attr :kpis, :list, required: true

  def changes(assigns) do
    assigns =
      assign(
        assigns,
        :needing,
        assigns.kpis
        |> Enum.filter(&(&1.severity in [:bad, :warn]))
        |> Enum.sort_by(&Map.fetch!(@order, &1.severity))
      )

    ~H"""
    <p :if={@needing == []} class="text-sm text-base-content/60">
      Nothing is past its threshold or worse than last week.
    </p>
    <ol :if={@needing != []} class="flex list-decimal flex-col gap-2 pl-5 text-sm">
      <li :for={kpi <- @needing} data-test="change" data-kpi={kpi.key}>
        <a href={"#section-#{kpi.section}"} class="font-medium link link-hover">
          {kpi.title}: {format(kpi.format, kpi.value)}
        </a>
        <span class={[
          "badge badge-sm ml-1",
          kpi.severity == :bad && "badge-error",
          kpi.severity == :warn && "badge-warning"
        ]}>
          {kpi.severity}
        </span>
        <p class="text-base-content/70">{Map.fetch!(changes(), kpi.key)}</p>
      </li>
    </ol>
    """
  end

  def changes, do: @changes

  def limits(assigns) do
    ~H"""
    <ul class="flex list-disc flex-col gap-1 pl-5 text-sm text-base-content/70">
      <li>
        Message kinds are read from each message's opening text: senders are not recorded yet, so a
        message from you and one from main look the same.
      </li>
      <li>
        Token use is recorded from 2026-10-14; earlier turns have none, so cost per story starts
        then.
      </li>
      <li>
        A story's messages are counted against the story its agent holds now, not the one it held
        when the message arrived.
      </li>
      <li>
        "Ignored" offers over-count: an earlier trace found most of them claimed another way.
      </li>
    </ul>
    """
  end

  attr :values, :list, required: true
  attr :severity, :atom, required: true

  # The week's days as a line, scaled to their own range. Days with no data
  # break the line rather than reading as zero.
  defp sparkline(assigns) do
    points = assigns.values |> Enum.with_index() |> Enum.reject(fn {v, _i} -> is_nil(v) end)
    assigns = assign(assigns, :points, spark_points(points))

    ~H"""
    <svg
      viewBox="0 0 120 32"
      class={["h-8 w-28 shrink-0", severity_text(@severity)]}
      role="img"
      aria-label="This week by day"
    >
      <polyline
        :if={@points != ""}
        points={@points}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linejoin="round"
        stroke-linecap="round"
      />
      <text :if={@points == ""} x="60" y="20" text-anchor="middle" font-size="10" fill="currentColor">
        no data
      </text>
    </svg>
    """
  end

  defp spark_points([]), do: ""

  defp spark_points(points) do
    values = Enum.map(points, &elem(&1, 0))
    {low, high} = Enum.min_max(values)
    span = if high == low, do: 1, else: high - low

    Enum.map_join(points, " ", fn {value, i} ->
      x = 4 + i * (112 / 6)
      y = 28 - (value - low) / span * 24
      "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"
    end)
  end

  @doc "A rate in its own units."
  def format(_format, nil), do: "–"
  def format(:percent, value), do: "#{round(value * 100)}%"
  def format(:minutes, value), do: minutes(value)
  def format(:count, value), do: "#{value}"
  def format(:number, value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)
  def format(:tokens, value), do: compact(value)

  defp minutes(value) when value < 60, do: "#{round(value)}m"
  defp minutes(value), do: "#{div(round(value), 60)}h #{rem(round(value), 60)}m"

  defp compact(value) when value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  defp compact(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 1)}k"
  defp compact(value), do: "#{round(value)}"

  defp delta_text(%{previous: nil}), do: "no data last week"
  defp delta_text(%{value: nil}), do: "none this week"

  defp delta_text(%{format: :percent, value: v, previous: p}) do
    pts = round((v - p) * 100)
    "#{arrow(pts)} #{abs(pts)} pts vs last week"
  end

  defp delta_text(%{value: v, previous: p}) when p == 0, do: "#{arrow(v)} from 0 last week"

  defp delta_text(%{value: v, previous: p}) do
    change = round((v - p) / abs(p) * 100)
    "#{arrow(change)} #{abs(change)}% vs last week"
  end

  defp arrow(n) when n > 0, do: "▲"
  defp arrow(n) when n < 0, do: "▼"
  defp arrow(_n), do: "="

  defp delta_class(%{value: v, previous: p, better: better}) when is_number(v) and is_number(p) do
    cond do
      v == p -> "text-base-content/60"
      v > p == (better == :up) -> "text-success"
      true -> "text-error"
    end
  end

  defp delta_class(_kpi), do: "text-base-content/60"

  defp severity_border(:bad), do: "border-l-error"
  defp severity_border(:warn), do: "border-l-warning"
  defp severity_border(:good), do: "border-l-success"
  defp severity_border(:none), do: "border-l-base-300"

  defp severity_text(:bad), do: "text-error"
  defp severity_text(:warn), do: "text-warning"
  defp severity_text(:good), do: "text-success"
  defp severity_text(:none), do: "text-base-content/50"
end
