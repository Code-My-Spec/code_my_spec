defmodule CodeMySpecWeb.PromotionTiming.Charts do
  @moduledoc "Stacked ECharts options for completed promotion timings."

  alias CodeMySpec.PromotionQueue.Timings

  @colors ~w(#64748b #94a3b8 #2563eb #a855f7 #f97316 #14b8a6 #eab308 #22c55e)

  @spec daily([Timings.timing()], map()) :: map()
  def daily(timings, zoom) do
    days =
      timings
      |> Enum.group_by(&(DateTime.to_date(&1.completed_at) |> Date.to_iso8601()))
      |> Enum.sort_by(&elem(&1, 0))

    categories = Enum.map(days, &elem(&1, 0))

    series =
      Enum.map(Timings.stages(), fn stage ->
        values = Enum.map(days, fn {_day, entries} -> median_stage(entries, stage) end)
        stage_series(stage, values)
      end)

    option(categories, series, zoom)
  end

  @spec per_entry([Timings.timing()], map()) :: map()
  def per_entry(timings, zoom) do
    entries =
      Enum.sort_by(timings, fn entry ->
        {if(entry.outcome == :landed, do: 0, else: 1), entry.completed_at, entry.id}
      end)

    categories =
      Enum.map(entries, fn entry ->
        outcome = entry.outcome |> Atom.to_string() |> String.capitalize()
        "#{outcome} #{String.slice(entry.id, 0, 8)}"
      end)

    series =
      Enum.map(Timings.stages(), fn stage ->
        values = Enum.map(entries, &stage_duration(&1, stage))
        stage_series(stage, values)
      end)

    option(categories, series, zoom)
  end

  defp median_stage(entries, stage) do
    values =
      entries |> Enum.map(&stage_duration(&1, stage)) |> Enum.reject(&is_nil/1) |> Enum.sort()

    count = length(values)

    cond do
      count == 0 -> nil
      rem(count, 2) == 1 -> Enum.at(values, div(count, 2))
      true -> (Enum.at(values, div(count, 2) - 1) + Enum.at(values, div(count, 2))) / 2
    end
  end

  defp stage_duration(entry, stage) do
    case Map.fetch!(entry.stages, stage) do
      %{status: :ran, duration_seconds: seconds} -> seconds
      _ -> nil
    end
  end

  defp stage_series(stage, values) do
    index = Enum.find_index(Timings.stages(), &(&1 == stage))

    %{
      name: stage,
      type: "bar",
      stack: "promotion-time",
      data: values,
      itemStyle: %{color: Enum.at(@colors, index)}
    }
  end

  defp option(categories, series, zoom) do
    %{
      tooltip: %{trigger: "axis", axisPointer: %{type: "shadow"}},
      legend: %{type: "scroll"},
      grid: %{left: 60, right: 24, top: 60, bottom: 95},
      xAxis: %{type: "category", data: categories, axisLabel: %{rotate: 30}},
      yAxis: %{type: "value", name: "Seconds"},
      dataZoom: [
        %{type: "slider", start: zoom.start, end: zoom.end, bottom: 20},
        %{type: "inside", start: zoom.start, end: zoom.end}
      ],
      series: series
    }
  end
end
