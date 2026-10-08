defmodule CodeMySpecWeb.WorkingCopyLive.Components.Agent do
  @moduledoc "An agent and its offers, questions and tap-outs, with a stable identity color."
  use CodeMySpecWeb, :html

  alias CodeMySpecWeb.WorkingCopyLive.Components

  @doc "A deterministic color derived from the agent ID, shared across renders and surfaces."
  def color(id) do
    <<value::unsigned-32, _::binary>> = :crypto.hash(:sha256, id)
    "hsl(#{rem(value, 360)}, 65%, 48%)"
  end

  attr(:agent, :map, required: true)

  def summary(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <span
        class="inline-block size-3 rounded-full"
        style={"background-color: #{color(@agent.id)}"}
        aria-hidden="true"
      />
      <h2 class="font-semibold">
        {if @agent.role == :qa, do: "QA", else: String.capitalize(to_string(@agent.role))}
      </h2>
      <span class="text-xs font-mono opacity-60">{String.slice(@agent.id, 0, 8)}</span>
      <span class="badge badge-sm">{@agent.status}</span>
    </div>
    """
  end

  attr(:team, :map, required: true)
  attr(:agents, :map, required: true)
  attr(:filtered, :boolean, default: false)

  def detail(assigns) do
    ~H"""
    <section
      id={"agent-#{@team.agent.id}"}
      data-test="status-agent"
      data-agent-id={@team.agent.id}
      class="rounded border border-base-300 border-l-4 p-4"
      style={"border-left-color: #{color(@team.agent.id)}"}
    >
      <.summary agent={@team.agent} />
      <div
        :if={not @filtered}
        data-test="agent-chart-band"
        class="mt-3 flex flex-wrap items-start gap-4 border-y border-base-300 py-3"
      >
        <Components.Offers.chart agent_id={@team.agent.id} results={@team.offer_results} />
      </div>
      <div class="mt-4 space-y-3">
        <details
          open={@filtered}
          id={"questions-#{@team.agent.id}"}
          class="rounded border border-base-300 p-3"
        >
          <summary class="cursor-pointer">
            <Components.Questions.summary questions={@team.questions} />
          </summary>
          <div class="mt-3">
            <Components.Questions.detail questions={@team.questions} agents={@agents} />
          </div>
        </details>
        <details
          open={@filtered}
          id={"tap-outs-#{@team.agent.id}"}
          class="rounded border border-base-300 p-3"
        >
          <summary class="cursor-pointer">
            <Components.TapOuts.summary tap_outs={@team.tap_outs} />
          </summary>
          <div class="mt-3">
            <Components.TapOuts.detail tap_outs={@team.tap_outs} agents={@agents} />
          </div>
        </details>
      </div>
    </section>
    """
  end
end
