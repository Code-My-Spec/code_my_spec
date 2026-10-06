defmodule CodeMySpecWeb.AgentPerformanceLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AgentPerformance
  alias CodeMySpec.AgentPerformance.Stage
  alias CodeMySpec.WorkingCopies

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:section, :agent_performance)
     |> assign(:page_title, "Agent Performance")}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{scope: %{}}} = socket) do
    {:noreply, load(socket, params)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    query =
      %{}
      |> maybe_put_param("working_copy_id", present(params["working_copy_id"]))
      |> maybe_put_param("story_id", present(params["story_id"]))

    {:noreply,
     push_patch(socket, to: ~p"/app/projects/#{socket.assigns.project.id}/agent-performance?#{query}")}
  end

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, key, value), do: Map.put(map, key, value)

  defp load(socket, params) do
    scope = socket.assigns.current_scope
    filter = chart_filter(params)
    stories = AgentPerformance.list_stories(scope)
    reports = Map.new(stories, &{&1.id, AgentPerformance.story_report(scope, &1)})

    teams =
      stories
      |> Enum.map(& &1.working_copy_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, AgentPerformance.team_first_pass_rate(scope, &1)})

    socket
    |> assign(:stories, stories)
    |> assign(:reports, reports)
    |> assign(:teams, teams)
    |> assign(:summary, AgentPerformance.summary(scope))
    |> assign(:filter, filter)
    |> assign(:working_copies, WorkingCopies.list_harnesses(scope))
    |> assign(:chart_option, AgentPerformance.chart_option(scope, filter))
    |> assign(:chart_detail, AgentPerformance.chart_detail(scope, filter))
  end

  defp chart_filter(params) do
    %{}
    |> maybe_put_filter(:working_copy_id, present(params["working_copy_id"]))
    |> maybe_put_filter(:story_id, parse_int(params["story_id"]))
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp maybe_put_filter(map, _key, nil), do: map
  defp maybe_put_filter(map, key, value), do: Map.put(map, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <.header>Agent Performance</.header>

    <form phx-change="filter" data-test="performance-filter" class="mt-4 flex flex-wrap gap-4 items-end">
      <div>
        <label class="label" for="filter-working-copy">Working copy</label>
        <select id="filter-working-copy" name="working_copy_id" class="select select-bordered select-sm">
          <option value="">All</option>
          <option
            :for={wc <- @working_copies}
            value={wc.id}
            selected={wc.id == @filter[:working_copy_id]}
          >
            {WorkingCopies.display_name(wc)}
          </option>
        </select>
      </div>
      <div>
        <label class="label" for="filter-story">Story</label>
        <select id="filter-story" name="story_id" class="select select-bordered select-sm">
          <option value="">All</option>
          <option :for={story <- @stories} value={story.id} selected={story.id == @filter[:story_id]}>
            {story.title}
          </option>
        </select>
      </div>
    </form>

    <section data-test="performance-chart" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Activity over time
      </h2>
      <div
        id="performance-chart"
        phx-hook="EChart"
        phx-update="ignore"
        data-option={Jason.encode!(@chart_option)}
        style="width: 100%; height: 360px;"
      >
      </div>
      <div data-test="chart-detail" class="mt-2 flex gap-4 text-sm text-base-content/70">
        <span data-test="chart-detail-tokens">{chart_tokens_label(@chart_detail.tokens_total)}</span>
        <span data-test="chart-detail-nudges">Nudges: {@chart_detail.nudges}</span>
      </div>
    </section>

    <section data-test="project-interventions" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Project-level interventions
      </h2>
      <p :if={@summary.project_level_interventions == []} class="text-base-content/60">
        None -- every intervention served a story.
      </p>
      <p :if={@summary.project_level_interventions != []} data-test="project-interventions-summary">
        {length(@summary.project_level_interventions)} total ({intervention_kind_counts(@summary.project_level_interventions)})
      </p>
    </section>

    <section data-test="project-blocked" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Blocked time
      </h2>
      <p :if={@summary.project_level_blocked == []} class="text-base-content/60">
        None -- nothing is waiting on a person right now.
      </p>
      <div :for={b <- @summary.project_level_blocked} data-test="blocked-time" data-cause={b.cause}>
        waiting on {waiting_on_label(b.waiting_on)} ({cause_label(b.cause)}): {hours(b.seconds)}
        <span :if={not b.resolved?}>-- lapsed, still unresolved</span>
      </div>
    </section>

    <section data-test="teams" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Teams</h2>
      <div :for={{working_copy_id, rate} <- @teams} data-test="team" data-working-copy-id={working_copy_id}>
        First-pass rate: {percent(rate)}
        <span>Promoted: {Map.get(@summary.throughput_by_team, working_copy_id, 0)}</span>
      </div>
    </section>

    <section data-test="offer-health" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Offer health</h2>
      <div :for={h <- @summary.offer_health} data-test="offer-health-role" data-role={h.role}>
        <span>{h.role}</span> -- claim rate {percent(h.claim_rate)}
        <span :if={h.claim_rate != nil}>, ignored {h.ignored}, declined {h.declined}</span>
        <span :if={h.superseded > 0}>, superseded {h.superseded}</span>
      </div>
    </section>

    <section data-test="stories" class="mt-6 space-y-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Stories</h2>
      <div :for={story <- @stories} id={"story-#{story.id}"} data-test="story" class="card bg-base-100 shadow-md">
        <div class="card-body">
          <h3 class="card-title">{story.title}</h3>
          {cycle_time_block(Map.fetch!(@reports, story.id).cycle_time)}
          {qa_rounds_block(Map.fetch!(@reports, story.id).qa_rounds)}
          {blocked_block(Map.fetch!(@reports, story.id).cycle_time)}
          {interventions_block(Map.fetch!(@reports, story.id).interventions)}
          {tokens_block(Map.fetch!(@reports, story.id).tokens)}
        </div>
      </div>
    </section>

    <section data-test="agents" class="mt-6 space-y-2">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Agents</h2>
      <div
        :for={agent <- @summary.agents}
        id={"agent-#{agent.agent_id}"}
        data-test="agent-row"
        class="flex items-center gap-4"
      >
        <.link navigate={"/app/projects/#{@project.id}/agent-performance/#{agent.agent_id}"}>
          {agent.role} ({agent.provider})
        </.link>
        <span>tool failures: {agent.tool_failures.failed_calls}</span>
        <span :for={f <- agent.reliability}>failed turn: {f.cause}</span>
      </div>
    </section>
    """
  end

  defp cycle_time_block(cycle_time) do
    assigns = %{cycle_time: cycle_time}

    ~H"""
    <div data-test="cycle-time" data-status={@cycle_time.status}>
      <span :if={@cycle_time.status == :in_flight}>Still running</span>
      <span :if={@cycle_time.status == :finished}>Total: {hours(@cycle_time.total_seconds)}</span>
      <div :for={stage <- Stage.names()} data-test="stage" data-stage={stage}>
        {stage}: {hours(Map.get(@cycle_time.stages, stage, 0))}
      </div>
    </div>
    """
  end

  defp qa_rounds_block(%{measured?: false}) do
    assigns = %{}

    ~H"""
    <div data-test="qa-rounds">First-pass rate: not yet measured (no QA attempt)</div>
    """
  end

  defp qa_rounds_block(qa_rounds) do
    assigns = %{qa_rounds: qa_rounds}

    ~H"""
    <div data-test="qa-rounds">
      <span>Rounds: {@qa_rounds.rounds}</span>
      <span :if={@qa_rounds.first_time_pass?}>first-time pass</span>
      <span :if={not @qa_rounds.first_time_pass?}>no first-time pass</span>
      <span :if={@qa_rounds.findings != []} data-test="qa-findings-count">
        {length(@qa_rounds.findings)} finding(s)
      </span>
      <ul>
        <li :for={finding <- @qa_rounds.findings}>{finding}</li>
      </ul>
    </div>
    """
  end

  defp blocked_block(%{blocked: []}), do: nil

  defp blocked_block(cycle_time) do
    assigns = %{blocked: cycle_time.blocked}

    ~H"""
    <div :for={b <- @blocked} data-test="blocked-time" data-cause={b.cause}>
      waiting on {waiting_on_label(b.waiting_on)} ({cause_label(b.cause)}): {hours(b.seconds)}
      <span :if={not b.resolved?}>-- lapsed, still unresolved</span>
    </div>
    """
  end

  defp cause_label(:tap_out), do: "tap-out"
  defp cause_label(cause), do: to_string(cause)

  defp waiting_on_label(:another_team), do: "another team"
  defp waiting_on_label(:main_agent), do: "the main agent"
  defp waiting_on_label(:user), do: "the user"

  defp interventions_block([]), do: nil

  defp interventions_block(interventions) do
    assigns = %{interventions: interventions}

    ~H"""
    <div data-test="story-interventions">
      <span>{length(@interventions)}</span> intervention(s) ({intervention_kind_counts(@interventions)})
      <div :for={i <- @interventions} data-test="intervention">
        {kind_label(i.kind)} ({i.reason})
      </div>
    </div>
    """
  end

  defp kind_label(:nudge), do: "nudge"
  defp kind_label(:restart), do: "restart"

  defp intervention_kind_counts(interventions) do
    interventions
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, items} -> "#{length(items)} #{kind_label(kind)}" end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp tokens_block(%{total: :unknown}), do: nil

  defp tokens_block(tokens) do
    assigns = %{tokens: tokens}

    ~H"""
    <div data-test="story-tokens">
      <span>{@tokens.total} tokens</span>
      <span :for={{provider, total} <- @tokens.by_provider} data-test="story-tokens-by-provider">
        {provider}: {total}
      </span>
    </div>
    """
  end

  defp chart_tokens_label(:unknown), do: "unknown"
  defp chart_tokens_label(total), do: "#{total} tokens"

  defp hours(nil), do: "unknown"
  defp hours(seconds), do: "#{div(seconds, 3600)}h"

  defp percent(nil), do: "not yet measured"
  defp percent(rate), do: "#{round(rate * 100)}%"
end
