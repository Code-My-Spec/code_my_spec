defmodule CodeMySpecLocalWeb.CoreComponents do
  @moduledoc """
  Shared components for the local web interface.
  """
  use Phoenix.Component

  @doc """
  Renders a checklist of steps with status indicators.
  """
  attr :evaluated, :list, required: true
  attr :base_path, :string, required: true
  attr :dir_param, :string, required: true

  def checklist(assigns) do
    ~H"""
    <table class="checklist">
      <tr :for={{step, status} <- @evaluated} class={status_css(status)}>
        <td class="icon"><%= status_icon(status) %></td>
        <td>
          <%= case status do %>
            <% :done -> %>
              <%= step.name %>
            <% :blocked -> %>
              <%= step.name %> <span class="tag">blocked</span>
            <% {:not_done, detail} -> %>
              <a href={"#{@base_path}/#{step.id}?dir=#{@dir_param}"}><%= step.name %></a>
              <span class="detail"><%= detail %></span>
          <% end %>
        </td>
      </tr>
    </table>
    """
  end

  @doc """
  Renders a progress bar.
  """
  attr :done, :integer, required: true
  attr :total, :integer, required: true

  def progress(assigns) do
    pct = if assigns.total > 0, do: round(assigns.done / assigns.total * 100), else: 0
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="subtitle"><%= @done %> of <%= @total %> steps complete</div>
    <div class="progress"><div class="progress-bar" style={"width: #{@pct}%"}></div></div>
    """
  end

  defp status_css(:done), do: "done"
  defp status_css(:blocked), do: "blocked"
  defp status_css({:not_done, _}), do: "actionable"

  defp status_icon(:done), do: Phoenix.HTML.raw("&#10003;")
  defp status_icon(:blocked), do: Phoenix.HTML.raw("&#9744;")
  defp status_icon({:not_done, _}), do: Phoenix.HTML.raw("&#9744;")
end
