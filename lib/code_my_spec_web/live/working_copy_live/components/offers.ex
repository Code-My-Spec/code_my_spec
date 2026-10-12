defmodule CodeMySpecWeb.WorkingCopyLive.Components.Offers do
  @moduledoc "Offer result chart for an agent."
  use CodeMySpecWeb, :html

  attr(:agent_id, :string, required: true)
  attr(:results, :map, required: true)

  def chart(assigns) do
    data =
      assigns.results
      |> Enum.sort_by(fn {status, _} -> status end)
      |> Enum.map(fn {status, count} ->
        %{
          name: status |> to_string() |> String.replace("_", " ") |> String.capitalize(),
          value: count
        }
      end)

    assigns =
      assigns
      |> assign(:data, data)
      |> assign(:total, Enum.sum(Map.values(assigns.results)))
      |> assign(:description, Enum.map_join(data, ", ", &"#{&1.name}: #{&1.value}"))

    ~H"""
    <div class="w-full sm:w-80 shrink-0" data-test="offer-results">
      <p class="text-xs opacity-60">Offers ({@total})</p>
      <p :if={@total == 0} class="py-3 text-sm opacity-60">No offers recorded.</p>
      <div
        :if={@total > 0}
        id={"offer-results-#{@agent_id}"}
        phx-hook="OfferResults"
        phx-update="ignore"
        data-results={Jason.encode!(@data)}
        role="img"
        aria-label={"Offer results: #{@description}"}
        class="w-full"
        style={"height: #{max(144, length(@data) * 25 + 16)}px"}
      />
    </div>
    """
  end
end
