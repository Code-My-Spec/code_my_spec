defmodule CodeMySpecWeb.PromotionTiming.StageTable do
  @moduledoc "Stage durations for one promotion or one outcome summary."
  use CodeMySpecWeb, :html

  alias CodeMySpec.PromotionQueue.Timings

  attr :timing, :map, required: true

  def detail(assigns) do
    ~H"""
    <div class="space-y-2">
      <div
        :for={stage <- Timings.stages()}
        data-test={"promotion-stage-#{stage}"}
        data-status={status(@timing.stages[stage])}
        data-duration-seconds={@timing.stages[stage].duration_seconds}
        class="flex gap-3"
      >
        <span>{label(stage)}</span>
        <span>{format_stage(@timing.stages[stage])}</span>
      </div>
    </div>
    """
  end

  attr :outcome, :string, required: true
  attr :stages, :map, required: true

  def summary(assigns) do
    ~H"""
    <div
      :for={{stage, figures} <- @stages}
      data-test={"promotion-summary-#{@outcome}-#{stage}"}
      class="flex flex-wrap gap-4"
    >
      <strong>{label(stage)}</strong>
      <span data-stat="median" data-duration-seconds={figures["median_seconds"]}>Median: {seconds(
        figures["median_seconds"]
      )}</span>
      <span data-stat="p90" data-duration-seconds={figures["p90_seconds"]}>P90: {seconds(
        figures["p90_seconds"]
      )}</span>
      <span data-stat="total" data-duration-seconds={figures["total_seconds"]}>Total: {seconds(
        figures["total_seconds"]
      )}</span>
    </div>
    """
  end

  defp status(%{status: :not_run}), do: "not-run"
  defp status(%{status: :ran}), do: "ran"
  defp label(stage), do: stage |> String.replace("-", " ") |> String.capitalize()
  defp format_stage(%{status: :not_run}), do: "Not run"
  defp format_stage(%{duration_seconds: value}), do: seconds(value)
  defp seconds(value), do: "#{value}s"
end
