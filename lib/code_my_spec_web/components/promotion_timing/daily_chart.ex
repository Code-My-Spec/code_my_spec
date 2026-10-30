defmodule CodeMySpecWeb.PromotionTiming.DailyChart do
  @moduledoc "Daily median stage durations for promotion timing."
  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.PromotionTiming.Charts

  attr :timings, :list, required: true
  attr :zoom, :map, required: true

  def chart(assigns) do
    assigns = assign(assigns, :option, Charts.daily(assigns.timings, assigns.zoom))

    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Daily median stage time</h2>
      <div
        id="promotion-daily-stage-chart"
        phx-hook="EChart"
        data-zoom-event="promotion-zoom"
        data-test="promotion-daily-stage-chart"
        data-option={Jason.encode!(@option)}
        role="img"
        aria-label="Stacked bar chart of daily median promotion stage durations"
        style="height: 360px"
      >
      </div>
    </section>
    """
  end
end
