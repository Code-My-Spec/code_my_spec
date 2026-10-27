defmodule CodeMySpecWeb.PromotionTiming.PerPromotionChart do
  @moduledoc "Stage durations for individual promotions grouped by outcome."
  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.PromotionTiming.Charts

  attr :timings, :list, required: true
  attr :zoom, :map, required: true

  def chart(assigns) do
    assigns = assign(assigns, :option, Charts.per_entry(assigns.timings, assigns.zoom))

    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Individual promotions</h2>
      <div
        id="promotion-per-entry-chart"
        phx-hook="EChart"
        data-zoom-event="promotion-zoom"
        data-test="promotion-per-entry-chart"
        data-option={Jason.encode!(@option)}
        role="img"
        aria-label="Stacked bar chart of individual promotion stage durations grouped by outcome"
        style="height: 400px"
      >
      </div>
    </section>
    """
  end
end
