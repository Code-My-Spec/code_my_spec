defmodule CodeMySpecWeb.AgentPerformanceLive.Index do
  @moduledoc """
  The performance page: what the project is doing, and a report per story.

  Issue 5d359bb3: on a real project (166 stories, 180 agents) the *join* was
  the wall, not the render. `handle_params` ran the whole read -- `Page.load`,
  then the chart's option and detail, plus the agent listing -- and took
  10.4-14.6s, past the Phoenix JS client's 10s `DEFAULT_TIMEOUT`, so the join
  was abandoned, the LiveView sat in `phx-error phx-server-error` and never
  reconnected, and the filter form's `phx-change` never fired. The three
  selects (criteria 2050, 2052, 2053) were unreachable at real scale even
  though the same narrowing through the query params worked server-side.

  So the join no longer waits for the read:

    * `handle_params` reads only what the page's *frame* needs -- the filter
      values, the working copies and the agents for the selects (four queries,
      or one fewer with nothing to filter by) -- and assigns
      `:page_loading?`/`:loading?` true.
    * The report itself is loaded behind `start_async/3`, which runs each
      loader in its own task and sends the result to the LiveView when it is
      done. The join replies as soon as the frame is assigned; the numbers
      arrive a moment later, and `handle_async :report` puts them in the
      socket the same way the old synchronous assign did.
    * A select change pushes a patch like it always did, so the URL stays
      `?working_copy_id=...` and the page is still linkable; `handle_params`
      then re-reads the frame with the new filter and starts the read again,
      showing the loading state while it runs.

  The selects are populated before the read completes, so they are usable on
  the page as soon as the join replies -- which is the point of the change
  rather than a side effect of it. What is *not* here: a longer socket
  timeout. `endpoint.ex` is the whole app's websocket contract and this page
  is not special enough to move it.

  The loading state is deliberately not a spinner over nothing: the *frame*
  is what the page already knows (title, filter options, which filter is on)
  and the parts that come from the read say "Loading" until they arrive.
  """

  use CodeMySpecWeb, :live_view

  # The frame replies in milliseconds; this bounds how long the *report* may
  # take before the page stops promising one. The real project's report reads in
  # 0.5-1.4s, so this is generous rather than tight -- it exists so that a task
  # that queue-waits forever shows a sentence instead of "Loading..." (issue
  # b118c546), not to cut off a slow-but-working read.
  @report_timeout 20_000

  alias CodeMySpec.AgentPerformance
  alias CodeMySpec.AgentPerformance.Page
  alias CodeMySpec.AgentPerformance.Stage
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:section, :agent_performance)
     |> assign(:page_title, "Agent Performance")
     |> assign(:page_loading?, true)
     |> assign(:loading?, true)}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{scope: %{}}} = socket) do
    {:noreply, load(socket, params)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # The report's own read, in its own task. `start_async/3` starts it and
  # replies to the join immediately; the result lands in `handle_async/3`
  # below. `async_page/2` is what would run if this page were ever inlined
  # into a bigger page's `assign_async` group.
  @impl true
  def handle_async(:report, {:ok, %{report: report}}, socket) do
    {:noreply, assign_report(socket, report)}
  end

  # The read failed, or took longer than this page is willing to make a person
  # wait. The frame -- including the selects -- stays up and the page says so,
  # rather than spinning forever or rendering a stale report from another filter
  # as if it were this one's.
  #
  # The timeout is not decoration: QA attempt 4 (issue b118c546) watched
  # "Loading..." for 90s+ on the real 188-agent project because the failure it
  # actually hit was a `DBConnection` queue timeout *inside* the task -- an exit
  # that, without this, leaves the assign loading and the page silent. A task
  # taking this long is not going to finish usefully, and a person is better
  # served by a sentence than by a promise.
  def handle_async(:report, {:exit, reason}, socket) do
    {:noreply, report_failed(socket, reason)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      %{}
      |> maybe_put_param("working_copy_id", present(params["working_copy_id"]))
      |> maybe_put_param("story_id", present(params["story_id"]))
      |> maybe_put_param("agent_id", present(params["agent_id"]))

    {:noreply,
     push_patch(socket, to: ~p"/app/projects/#{socket.assigns.project.id}/agent-performance?#{query}")}
  end

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, key, value), do: Map.put(map, key, value)

  # The frame first -- the filter values, the working copies and the agents --
  # then the read, asynchronously. Three queries plus `list_harnesses/1`'s own
  # listing, and none of them scale with the project.
  defp load(socket, params) do
    scope = socket.assigns.current_scope
    filter = chart_filter(params)

    socket
    |> assign(:filter, filter)
    |> assign(:working_copies, WorkingCopies.list_harnesses(scope))
    |> assign(:agents, AgentPerformance.list_agents(scope))
    # The story select needs titles, not the report's story structs: leaving
    # `@stories` empty until the read landed left the select with no options
    # on the render the join replied with -- the one render a person sees
    # first. `list_story_titles/1` selects three fields for the whole project.
    |> assign(:story_options, Stories.list_story_titles(scope))
    # The report's own fields, empty until `handle_async :report` assigns the
    # read. The template renders the frame before the read arrives, so every
    # field it reads has to exist -- on the first (HTTP) render and on a
    # re-read after a select patch alike. `:chart_option`/`:chart_detail` are
    # left to the loading branches, which do not read them.
    |> assign(:stories, [])
    |> assign(:reports, %{})
    |> assign(:teams, [])
    |> assign(:summary, %{
      agents: [],
      offer_health: [],
      project_level_interventions: [],
      project_level_blocked: [],
      throughput_by_team: %{}
    })
    |> assign(:report_error, nil)
    |> assign(:page_loading?, true)
    |> assign(:loading?, true)
    |> start_async_report(scope, filter)
  end

  defp start_async_report(socket, scope, filter) do
    if connected?(socket) do
      start_async(socket, :report, fn -> %{report: report(scope, filter)} end,
        timeout: @report_timeout
      )
    else
      # The first (HTTP) render has no task to deliver into -- `start_async`
      # would leave it loading forever. It reads synchronously, which is the
      # old cost, and the connected mount replaces it before anyone can click.
      assign_report(socket, report(scope, filter))
    end
  end

  defp report_failed(socket, reason) do
    socket
    |> assign(:page_loading?, false)
    |> assign(:loading?, false)
    |> assign(:report_error, failure_text(reason))
  end

  defp failure_text(:timeout),
    do: "the report took longer than #{div(@report_timeout, 1000)}s to read"

  defp failure_text(reason), do: inspect(reason)

  defp report(scope, filter) do
    page = Page.load(scope)

    %{
      stories: page.stories,
      reports: page.reports,
      teams: page.teams,
      summary: page.summary,
      chart_option: AgentPerformance.chart_option(scope, filter),
      chart_detail: AgentPerformance.chart_detail(scope, filter)
    }
  end

  defp assign_report(socket, report) do
    socket
    |> assign(:stories, report.stories)
    |> assign(:reports, report.reports)
    |> assign(:teams, report.teams)
    |> assign(:summary, report.summary)
    |> assign(:chart_option, report.chart_option)
    |> assign(:chart_detail, report.chart_detail)
    |> assign(:page_loading?, false)
    |> assign(:loading?, false)
  end

  defp chart_filter(params) do
    %{}
    |> maybe_put_filter(:working_copy_id, present(params["working_copy_id"]))
    |> maybe_put_filter(:story_id, parse_int(params["story_id"]))
    |> maybe_put_filter(:agent_id, present(params["agent_id"]))
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
          <option :for={story <- @story_options} value={story.id} selected={story.id == @filter[:story_id]}>
            {story.title}
          </option>
        </select>
      </div>
      <div>
        <label class="label" for="filter-agent">Agent</label>
        <select id="filter-agent" name="agent_id" class="select select-bordered select-sm">
          <option value="">All</option>
          <option :for={agent <- @agents} value={agent.id} selected={agent.id == @filter[:agent_id]}>
            {agent_label(agent)}
          </option>
        </select>
      </div>
      <span :if={@page_loading?} data-test="performance-loading" class="text-sm text-base-content/60">
        Loading...
      </span>
    </form>

    <%!--
      A failed read keeps the frame: the selects above still work and the page
      says what happened rather than showing an empty report.
    --%>
    <p :if={@report_error} data-test="performance-error" class="mt-4 text-sm text-error">
      The report could not be read: {@report_error}
    </p>

    <section data-test="performance-chart" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Activity over time
      </h2>
      <div
        :if={not @page_loading?}
        id="performance-chart"
        phx-hook="EChart"
        phx-update="ignore"
        data-option={Jason.encode!(@chart_option)}
        style="width: 100%; height: 360px;"
      >
      </div>
      <div :if={@page_loading?} data-test="chart-loading" class="h-[360px] w-full animate-pulse rounded bg-base-200">
      </div>
      <div data-test="chart-detail" class="mt-2 flex gap-4 text-sm text-base-content/70">
        <span :if={not @page_loading?} data-test="chart-detail-tokens">{chart_tokens_label(@chart_detail.tokens_total)}</span>
        <span :if={not @page_loading?} data-test="chart-detail-nudges">
          Nudges: {@chart_detail.nudges}
        </span>
      </div>
      <p :if={@page_loading?} data-test="chart-detail-loading" class="mt-2 text-sm text-base-content/60">
        Loading the chart's detail...
      </p>
    </section>

    <section data-test="project-interventions" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Project-level interventions
      </h2>
      <p :if={@loading?} data-test="project-interventions-loading" class="text-base-content/60">
        Loading...
      </p>
      <p :if={not @loading? and @summary.project_level_interventions == []} class="text-base-content/60">
        None -- every intervention served a story.
      </p>
      <p
        :if={not @loading? and @summary.project_level_interventions != []}
        data-test="project-interventions-summary"
      >
        {length(@summary.project_level_interventions)} total ({intervention_kind_counts(@summary.project_level_interventions)})
      </p>
    </section>

    <section data-test="project-blocked" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Blocked time
      </h2>
      <p :if={@loading?} data-test="project-blocked-loading" class="text-base-content/60">
        Loading...
      </p>
      <p :if={not @loading? and @summary.project_level_blocked == []} class="text-base-content/60">
        None -- nothing is waiting on a person right now.
      </p>
      <div
        :for={b <- @summary.project_level_blocked}
        data-test="blocked-time"
        data-cause={b.cause}
      >
        waiting on {waiting_on_label(b.waiting_on)} ({cause_label(b.cause)}): {hours(b.seconds)}
        <span :if={not b.resolved?}>-- lapsed, still unresolved</span>
      </div>
    </section>

    <section data-test="teams" class="mt-6">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Teams</h2>
      <div
        :for={{working_copy_id, rate} <- @teams}
        data-test="team"
        data-working-copy-id={working_copy_id}
      >
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
      <p :if={@loading?} data-test="stories-loading" class="text-base-content/60">
        Loading the project's stories...
      </p>
      <div
        :for={story <- @stories}
        id={"story-#{story.id}"}
        data-test="story"
        class="card bg-base-100 shadow-md"
      >
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
      <p :if={@loading?} data-test="agents-loading" class="text-base-content/60">
        Loading the project's agents...
      </p>
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
        {stage}: {hours(Map.get(@cycle_time.stages, stage))}
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

  defp agent_label(agent), do: "#{agent.role} (#{agent.provider})"

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
