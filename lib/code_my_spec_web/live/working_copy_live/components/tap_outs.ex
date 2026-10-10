defmodule CodeMySpecWeb.WorkingCopyLive.Components.TapOuts do
  @moduledoc "Summary and details of a working copy's pending tap-outs."
  use CodeMySpecWeb, :html

  attr(:tap_outs, :list, required: true)

  def summary(assigns) do
    ~H"""
    <span>Tap-outs <span class="badge badge-sm">{length(@tap_outs)} pending</span></span>
    """
  end

  attr(:tap_outs, :list, required: true)
  attr(:agents, :map, required: true)

  def detail(assigns) do
    ~H"""
    <div class="space-y-3" data-test="tap-outs-detail">
      <p :if={@tap_outs == []} class="opacity-60">No pending tap-outs.</p>
      <article
        :for={request <- @tap_outs}
        class="rounded border border-base-300 border-l-2 p-3 space-y-2"
        style={"border-left-color: #{CodeMySpecWeb.WorkingCopyLive.Components.Agent.color(request.agent_id)}"}
      >
        <p class="whitespace-pre-wrap text-sm">
          {(request.tool_input || %{})["reason"] || "No reason recorded."}
        </p>
        <p :if={request.escalation_reason} class="whitespace-pre-wrap text-sm">
          {request.escalation_reason}
        </p>
        <p class="text-xs opacity-60">{request.inserted_at} · {request.id}</p>
      </article>
    </div>
    """
  end
end
