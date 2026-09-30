defmodule CodeMySpecWeb.AgentLoopBadge do
  @moduledoc """
  Whether an agent is in the loop, said where people look at agents.

  Graph wakes admit only continuous agents, so an agent with it off sits idle
  over ready work until somebody messages it — and nothing on screen said so
  (723b929d). One component so every page says it in the same words.
  """

  use Phoenix.Component

  @doc "`compact` drops the explanation, for a one-line row; the title keeps it."
  attr :continuous?, :boolean, required: true
  attr :compact, :boolean, default: false

  def loop_badge(assigns) do
    ~H"""
    <span
      data-test="agent-loop"
      data-continuous={to_string(@continuous?)}
      title={
        if @continuous?,
          do: "In the loop — the graph wakes it when work appears",
          else: "Not continuous — the graph won't wake it"
      }
      class={[
        "badge badge-sm shrink-0 whitespace-nowrap",
        if(@continuous?, do: "badge-success badge-soft", else: "badge-warning badge-soft")
      ]}
    >
      <%= if @continuous? do %>
        Continuous
      <% else %>
        Not continuous<span :if={!@compact} class="hidden sm:inline">&nbsp;— the graph won't wake it</span>
      <% end %>
    </span>
    """
  end
end
