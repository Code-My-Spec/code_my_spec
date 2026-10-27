defmodule CodeMySpecWeb.PromotionTiming.Counts do
  @moduledoc "Promotion counts and gate time for one outcome."
  use CodeMySpecWeb, :html

  attr :outcome, :string, required: true
  attr :figures, :map, required: true

  def summary(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold">{String.capitalize(@outcome)}: {@figures["count"]}</h2>
      <p
        data-test={"promotion-gate-time-#{@outcome}"}
        data-duration-seconds={@figures["gate_seconds"]}
      >
        Gate time: {@figures["gate_seconds"]}s
      </p>
    </div>
    """
  end
end
