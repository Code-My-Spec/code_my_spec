defmodule CodeMySpecSpex.AgentPerformanceHelpers do
  @moduledoc """
  Path builders for the agent-performance report (story 1092).

  Twenty criteria share these two paths -- the same reason
  `WorkingCopyHelpers` and `PromotionHelpers` exist for their own surfaces.
  """

  @doc "The summary page: headline numbers per team and per role."
  @spec index_path(map()) :: String.t()
  def index_path(context), do: "/app/projects/#{context.project.id}/agent-performance"

  @doc "One agent's detail page, reached from the index."
  @spec show_path(map(), %{id: String.t()}) :: String.t()
  def show_path(context, %{id: agent_id}),
    do: "/app/projects/#{context.project.id}/agent-performance/#{agent_id}"

  @doc """
  A chart's data as the page hands it to its EChart hook, decoded from the
  element's `data-option` -- what the person sees drawn, read without a browser.
  """
  @spec chart_data(Phoenix.LiveViewTest.View.t(), String.t()) :: map()
  def chart_data(view, selector) do
    view
    |> Phoenix.LiveViewTest.element(selector)
    |> Phoenix.LiveViewTest.render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("data-option")
    |> List.first()
    |> Jason.decode!()
  end

  @doc "One story's row in the time-per-story chart: its stage hours by name and its tooltip lines."
  @spec story_row(map(), String.t()) :: %{hours: %{String.t() => number()}, details: [String.t()]}
  def story_row(chart, title) do
    index = Enum.find_index(chart["categories"], &(&1 == title))

    %{
      hours: Map.new(chart["stacks"], &{&1["name"], Enum.at(&1["data"], index)}),
      details: Enum.at(chart["details"], index)
    }
  end
end
