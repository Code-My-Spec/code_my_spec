defmodule CodeMySpecWeb.WorkingCopyLive.Components.Issues do
  @moduledoc "The working copy's issue bag and each agent's active priority."
  use CodeMySpecWeb, :html

  attr :agent, :map, required: true
  attr :issues, :list, required: true

  def summary(assigns) do
    assigns =
      assign(assigns, :active, Enum.find(assigns.issues, &(&1.id == assigns.agent.issue_id)))

    ~H"""
    <div class="mt-2 text-sm" data-test="agent-assignment">
      <%= cond do %>
        <% @issues != [] -> %>
          <span class="badge badge-outline badge-sm">Issues ({length(@issues)})</span>
          <p class="mt-1">
            <%= if @active do %>
              Active issue: {@active.title}
            <% else %>
              No active issue selected
            <% end %>
          </p>
        <% @agent.story_id -> %>
          <span class="badge badge-outline badge-sm">Story assigned</span>
        <% true -> %>
          <span class="opacity-60">Unassigned</span>
      <% end %>
    </div>
    """
  end
end
