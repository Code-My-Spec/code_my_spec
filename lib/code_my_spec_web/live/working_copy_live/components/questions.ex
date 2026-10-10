defmodule CodeMySpecWeb.WorkingCopyLive.Components.Questions do
  @moduledoc "Summary and details of a working copy's pending questions."
  use CodeMySpecWeb, :html

  attr(:questions, :list, required: true)

  def summary(assigns) do
    ~H"""
    <span>Questions <span class="badge badge-sm">{length(@questions)} pending</span></span>
    """
  end

  attr(:questions, :list, required: true)
  attr(:agents, :map, required: true)

  def detail(assigns) do
    ~H"""
    <div class="space-y-3" data-test="questions-detail">
      <p :if={@questions == []} class="opacity-60">No pending questions.</p>
      <article
        :for={request <- @questions}
        class="rounded border border-base-300 border-l-2 p-3 space-y-2"
        style={"border-left-color: #{CodeMySpecWeb.WorkingCopyLive.Components.Agent.color(request.agent_id)}"}
      >
        <p class="font-medium">{request.title}</p>
        <p class="text-sm">
          Waiting on {request.holder}
        </p>
        <p :for={question <- request.questions} class="whitespace-pre-wrap text-sm">
          {question["question"]}
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
