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

  attr :issues, :list, required: true
  attr :teams, :list, required: true

  def detail(assigns) do
    assigns =
      assign(
        assigns,
        :active_ids,
        MapSet.new(
          Enum.flat_map(assigns.teams, fn team ->
            if is_nil(team.agent.retired_at), do: [team.agent.issue_id], else: []
          end)
        )
      )

    ~H"""
    <section data-test="working-copy-issue-bag" class="space-y-3">
      <h2 class="text-lg font-semibold">Issues ({length(@issues)})</h2>
      <div :for={issue <- @issues} data-issue-id={issue.id} class="rounded border border-base-300 p-4">
        <div class="flex items-start justify-between gap-3">
          <p class="font-medium">{issue.title}</p>
          <span :if={MapSet.member?(@active_ids, issue.id)} class="badge badge-primary badge-sm">
            Active
          </span>
        </div>
        <p class="mt-2 text-sm opacity-70">{stage(issue.awaiting_role)} · {issue.severity}</p>
      </div>
    </section>
    """
  end

  defp stage(:coding), do: "Awaiting coding"
  defp stage(:qa), do: "Awaiting QA"
  defp stage(:promote), do: "Awaiting promotion"
  defp stage(_), do: "Assigned"
end
