defmodule CodeMySpecWeb.IssueCharts do
  @moduledoc """
  Every issue over time for the `EChart` hook: at the end of each day, how many
  stood in each status, stacked — or, by severity, how many were still open.
  Where an issue stood is read from its times:
  incoming once created, accepted from `accepted_at`, and from `closed_at` the
  status it closed as. Closed at the bottom, so the open band rides on top.
  """
  use CodeMySpecWeb, :html

  @statuses [:resolved, :dismissed, :accepted, :incoming]
  @severities [:critical, :high, :medium, :low, :info]
  @colors %{
    resolved: "#22c55e",
    dismissed: "#94a3b8",
    accepted: "#3b82f6",
    incoming: "#eab308",
    critical: "#ef4444",
    high: "#f97316",
    medium: "#facc15",
    low: "#60a5fa",
    info: "#cbd5e1"
  }
  @ranges %{"7d" => 7, "30d" => 30, "90d" => 90}

  @doc "The ranges the chart offers, shortest first, then everything."
  def ranges, do: ~w(7d 30d 90d all)

  @doc "What the chart stacks by: every issue by status, or the open ones by severity."
  def views, do: ~w(status severity)

  attr :issues, :list, required: true
  attr :range, :string, required: true
  attr :view, :string, default: "status"
  attr :event, :string, required: true, doc: "pushed with `range` or `view`"
  attr :height, :integer, default: 220

  def open_over_time(assigns) do
    days = days(assigns.issues, assigns.range)
    option = option(assigns.view, assigns.issues, days)
    assigns = assign(assigns, option: option, empty?: assigns.issues == [])

    ~H"""
    <section data-test="issues-over-time" class="rounded-box border border-base-300 p-4">
      <div class="flex items-center justify-between gap-3">
        <div class="join" data-test="issues-view">
          <button
            :for={view <- views()}
            type="button"
            phx-click={@event}
            phx-value-view={view}
            data-view={view}
            class={["btn btn-xs join-item", view == @view && "btn-active"]}
          >
            {if view == "status", do: "By status", else: "Open by severity"}
          </button>
        </div>
        <div class="join" data-test="issues-range">
          <button
            :for={range <- ranges()}
            type="button"
            phx-click={@event}
            phx-value-range={range}
            data-range={range}
            class={["btn btn-xs join-item", range == @range && "btn-active"]}
          >
            {range}
          </button>
        </div>
      </div>
      <p :if={@empty?} class="py-6 text-center text-sm opacity-60">No issues.</p>
      <div
        :if={!@empty?}
        id={"issues-over-time-#{:erlang.phash2(@option)}"}
        phx-hook="EChart"
        phx-update="ignore"
        data-option={Jason.encode!(@option)}
        style={"height: #{@height}px"}
      >
      </div>
    </section>
    """
  end

  defp days(issues, range) do
    today = Date.utc_today()

    first =
      case Map.fetch(@ranges, range) do
        {:ok, n} ->
          Date.add(today, -(n - 1))

        :error ->
          issues |> Enum.map(&DateTime.to_date(&1.inserted_at)) |> Enum.min(Date, fn -> today end)
      end

    Date.range(first, today) |> Enum.to_list()
  end

  # Each day's count of issues in each band: by status, every issue where it
  # stood; by severity, only those still open.
  defp option(view, issues, days) do
    ends = Enum.map(days, &DateTime.new!(Date.add(&1, 1), ~T[00:00:00], "Etc/UTC"))
    bands = if view == "severity", do: @severities, else: @statuses

    by_day =
      Enum.map(ends, fn at -> issues |> Enum.map(&band(view, &1, at)) |> Enum.frequencies() end)

    %{
      categories: Enum.map(days, &Date.to_iso8601/1),
      series:
        for band <- bands do
          %{
            name: Atom.to_string(band),
            type: "line",
            stack: "issues",
            symbol: "none",
            areaStyle: %{},
            y_axis: "count",
            itemStyle: %{color: @colors[band]},
            lineStyle: %{width: 1},
            data: Enum.map(by_day, &Map.get(&1, band, 0))
          }
        end
    }
  end

  defp band("severity", issue, at) do
    if status_at(issue, at) in [:incoming, :accepted], do: issue.severity
  end

  defp band(_status, issue, at), do: status_at(issue, at)

  # Where an issue stood at `at`, or nil before it existed.
  defp status_at(issue, at) do
    cond do
      not before?(issue.inserted_at, at) -> nil
      issue.closed_at && before?(issue.closed_at, at) -> issue.status
      issue.accepted_at && before?(issue.accepted_at, at) -> :accepted
      true -> :incoming
    end
  end

  defp before?(time, at), do: DateTime.compare(time, at) == :lt
end
