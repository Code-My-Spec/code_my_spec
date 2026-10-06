defmodule CodeMySpecWeb.AgentPerformanceLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AgentPerformance

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:section, :agent_performance)}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, %{assigns: %{scope: %{}}} = socket) do
    case AgentPerformance.agent_detail(socket.assigns.current_scope, agent_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That agent could not be found.")
         |> push_navigate(to: ~p"/app/projects/#{socket.assigns.project.id}/agent-performance")}

      detail ->
        {:noreply,
         socket
         |> assign(:page_title, "#{detail.agent.role} agent")
         |> assign(:detail, detail)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.header :if={@detail}>{String.capitalize(to_string(@detail.agent.role))} agent</.header>

    <section :if={@detail} data-test="tokens" class="mt-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Token use</h2>
      <div data-test="provider">{@detail.tokens.provider || @detail.agent.provider}</div>
      <div data-test="model">{@detail.tokens.model}</div>
      <div data-test="input-tokens">Input: {token_label(@detail.tokens.input_tokens)}</div>
      <div data-test="output-tokens">Output: {token_label(@detail.tokens.output_tokens)}</div>
      <div data-test="cache-read-tokens">Cache read: {token_label(@detail.tokens.cache_read_tokens)}</div>
      <div data-test="cache-write-tokens">
        Cache write: {token_label(@detail.tokens.cache_write_tokens)}
      </div>
    </section>

    <section :if={@detail} data-test="tool-failures" class="mt-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Tool-call failures
      </h2>
      <div>
        {@detail.tool_failures.failed_calls} of {@detail.tool_failures.total_calls} calls failed
      </div>
      <div :for={{tool, count} <- @detail.tool_failures.by_tool} data-test="tool-failure">
        {tool}: {count}
      </div>
    </section>

    <section :if={@detail} data-test="reliability" class="mt-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Failed turns
      </h2>
      <p :if={@detail.reliability == []} class="text-base-content/60">None outstanding.</p>
      <div :for={f <- @detail.reliability} data-test="failed-turn">{f.cause}</div>
    </section>

    <section :if={@detail} data-test="interventions" class="mt-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Interventions
      </h2>
      <p :if={@detail.interventions == []} class="text-base-content/60">None.</p>
      <div :for={i <- @detail.interventions} data-test="intervention">
        {i.kind} ({i.reason})
      </div>
    </section>
    """
  end

  defp token_label(:unknown), do: "unknown"
  defp token_label(n), do: "#{n} tokens"
end
