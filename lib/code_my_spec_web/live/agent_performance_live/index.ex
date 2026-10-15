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
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.AgentPerformanceLive.Charts
  alias CodeMySpecWeb.AgentPerformanceLive.Scorecard
  alias CodeMySpecWeb.WorkingCopyLive.Components.Offers

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

  def handle_async(:offer_results, {:ok, results}, socket),
    do: {:noreply, assign(socket, offer_results: results, offer_loading?: false)}

  def handle_async(:offer_results, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, offer_results: %{}, offer_loading?: false)}

  @impl true
  def handle_event("offer_role", %{"role" => role}, socket) do
    role = Enum.find(Agent.roles(), &(to_string(&1) == role))
    scope = socket.assigns.current_scope
    filter = offer_filter(socket.assigns.filter, role)

    {:noreply,
     socket
     |> assign(offer_role: role, offer_loading?: true)
     |> start_async(:offer_results, fn -> AgentPerformance.offer_results(scope, filter) end)}
  end

  def handle_event("chart_page", %{"chart" => chart, "page" => page}, socket) do
    {key, data} =
      case chart do
        "stages" -> {:stage_page, socket.assigns.stage_chart}
        "agents" -> {:agent_page, socket.assigns.agent_chart}
      end

    page = page |> String.to_integer() |> max(1) |> min(Charts.page_count(data))
    {:noreply, assign(socket, key, page)}
  end

  def handle_event("filter", params, socket) do
    query =
      %{}
      |> maybe_put_param("working_copy_id", present(params["working_copy_id"]))
      |> maybe_put_param("story_id", present(params["story_id"]))
      |> maybe_put_param("agent_id", present(params["agent_id"]))

    {:noreply,
     push_patch(socket,
       to: ~p"/app/projects/#{socket.assigns.project.id}/agent-performance?#{query}"
     )}
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
    |> assign(:offer_results, %{})
    |> assign(:offer_role, socket.assigns[:offer_role])
    |> assign(:offer_loading?, false)
    |> assign(:qa_results, %{})
    |> assign(:intervention_results, %{})
    |> assign(:stage_chart, %{"categories" => []})
    |> assign(:blocked_chart, %{"categories" => []})
    |> assign(:team_chart, %{"categories" => []})
    |> assign(:agent_chart, %{"categories" => []})
    |> assign(:stage_page, 1)
    |> assign(:scorecard, %{kpis: []})
    |> assign(:role_chart, %{"categories" => []})
    |> assign(:tap_out_chart, %{"categories" => []})
    |> assign(:question_chart, %{"categories" => []})
    |> assign(:offer_kind_chart, %{"categories" => []})
    |> assign(:agent_page, 1)
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
      role = socket.assigns.offer_role

      start_async(socket, :report, fn -> %{report: report(scope, filter, role)} end,
        timeout: @report_timeout
      )
    else
      # The first (HTTP) render has no task to deliver into -- `start_async`
      # would leave it loading forever. It reads synchronously, which is the
      # old cost, and the connected mount replaces it before anyone can click.
      assign_report(socket, report(scope, filter, socket.assigns.offer_role))
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

  # The reads that do not need the page run beside `Page.load/1` rather than
  # after it: one after another they outgrew a render's wait.
  defp report(scope, filter, offer_role) do
    tasks =
      Map.new(
        %{
          chart_option: fn -> AgentPerformance.chart_option(scope, filter) end,
          rates_option: fn -> AgentPerformance.rates_option(scope, filter) end,
          chart_detail: fn -> AgentPerformance.chart_detail(scope, filter) end,
          offer_results: fn ->
            AgentPerformance.offer_results(scope, offer_filter(filter, offer_role))
          end,
          qa: fn -> AgentPerformance.qa_counts(scope, filter) end,
          scorecard: fn -> AgentPerformance.scorecard(scope, filter) end,
          working_copies: fn -> WorkingCopies.list_harnesses(scope) end
        },
        fn {key, read} -> {key, Task.async(read)} end
      )

    page = Page.load(scope)
    read = Map.new(tasks, fn {key, task} -> {key, Task.await(task, @report_timeout)} end)
    stories = Charts.stories(page.stories, page.reports, page.agents, filter)

    %{
      stage_chart: Charts.stages(stories, page.reports),
      blocked_chart:
        Charts.blocked(
          stories,
          page.reports,
          open_waits(page.summary.project_level_blocked, filter)
        ),
      intervention_results:
        Charts.message_kinds(page.summary.message_kinds_by_agent, page.agents, filter),
      qa_results: read.qa.total,
      scorecard: read.scorecard,
      role_chart: Charts.roles(read.scorecard.roles),
      tap_out_chart: Charts.tap_outs(read.scorecard.tap_outs),
      question_chart: Charts.questions(read.scorecard.questions),
      offer_kind_chart: Charts.offer_kinds(read.scorecard.offer_kinds),
      agent_chart: Charts.agents(page.summary.agents, page.agents, filter),
      team_chart:
        Charts.teams(
          page.teams,
          page.summary.throughput_by_team,
          read.qa.by_copy,
          read.working_copies
        ),
      stories: page.stories,
      reports: page.reports,
      teams: page.teams,
      summary: page.summary,
      chart_option: read.chart_option,
      rates_option: read.rates_option,
      chart_detail: read.chart_detail,
      offer_results: read.offer_results
    }
  end

  defp assign_report(socket, report) do
    socket
    |> assign(:stories, report.stories)
    |> assign(:reports, report.reports)
    |> assign(:teams, report.teams)
    |> assign(:summary, report.summary)
    |> assign(:chart_option, report.chart_option)
    |> assign(:rates_option, report.rates_option)
    |> assign(:chart_detail, report.chart_detail)
    |> assign(:offer_results, report.offer_results)
    |> assign(:qa_results, report.qa_results)
    |> assign(:intervention_results, report.intervention_results)
    |> assign(:stage_chart, report.stage_chart)
    |> assign(:blocked_chart, report.blocked_chart)
    |> assign(:team_chart, report.team_chart)
    |> assign(:scorecard, report.scorecard)
    |> assign(:role_chart, report.role_chart)
    |> assign(:tap_out_chart, report.tap_out_chart)
    |> assign(:question_chart, report.question_chart)
    |> assign(:offer_kind_chart, report.offer_kind_chart)
    |> assign(:agent_chart, report.agent_chart)
    |> assign(:page_loading?, false)
    |> assign(:loading?, false)
  end

  defp offer_filter(filter, nil), do: filter
  defp offer_filter(filter, role), do: Map.put(filter, :role, role)

  # Open waits belong to no story, so a story filter leaves them out.
  defp open_waits(_waits, %{story_id: _}), do: []
  defp open_waits(waits, _filter), do: waits

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

    <form
      phx-change="filter"
      data-test="performance-filter"
      class="mt-4 flex flex-wrap gap-4 items-end"
    >
      <div>
        <label class="label" for="filter-working-copy">Working copy</label>
        <select
          id="filter-working-copy"
          name="working_copy_id"
          class="select select-bordered select-sm"
        >
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
          <option
            :for={story <- @story_options}
            value={story.id}
            selected={story.id == @filter[:story_id]}
          >
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

    <section id="section-standouts" data-test="standouts" class="mt-6 scroll-mt-4">
      <.heading>What stands out</.heading>
      <p class="mb-2 text-xs text-base-content/60">
        This week against last. Click a card for the chart behind it.
      </p>
      <div :if={@page_loading?} class="h-40 w-full animate-pulse rounded bg-base-200"></div>
      <Scorecard.standouts :if={not @page_loading?} kpis={@scorecard.kpis} />
    </section>

    <section id="section-activity" data-test="performance-chart" class="mt-8 scroll-mt-4">
      <.heading>Activity over time</.heading>
      <div
        :if={not @page_loading?}
        id="performance-chart"
        phx-hook="EChart"
        phx-update="ignore"
        data-option={Jason.encode!(@chart_option)}
        style="width: 100%; height: 340px;"
      >
      </div>
      <div
        :if={@page_loading?}
        data-test="chart-loading"
        class="h-[340px] w-full animate-pulse rounded bg-base-200"
      >
      </div>
      <div data-test="chart-detail" class="mt-2 flex gap-4 text-sm text-base-content/70">
        <span :if={not @page_loading?} data-test="chart-detail-tokens">
          {chart_tokens_label(@chart_detail.tokens_total)}
        </span>
        <span :if={not @page_loading?} data-test="chart-detail-messages">
          Messages: {@chart_detail.messages}
        </span>
      </div>
      <p
        :if={@page_loading?}
        data-test="chart-detail-loading"
        class="mt-2 text-sm text-base-content/60"
      >
        Loading the chart's detail...
      </p>
      <div data-test="rates-chart" class="mt-6">
        <h3 class="text-xs font-medium text-base-content/70">Rates over time</h3>
        <div
          :if={not @page_loading?}
          id="rates-chart"
          phx-hook="EChart"
          phx-update="ignore"
          data-option={Jason.encode!(@rates_option)}
          style="width: 100%; height: 260px;"
        >
        </div>
        <div :if={@page_loading?} class="h-[260px] w-full animate-pulse rounded bg-base-200"></div>
        <p class="mt-1 text-xs text-base-content/60">
          Offer acceptance is the share of settled offers an agent claimed; tool failure rate is the
          share of tool calls that failed. Hours with neither are skipped.
        </p>
      </div>
    </section>

    <section id="section-roles" data-test="roles" class="mt-8 scroll-mt-4">
      <.heading>Activity by role</.heading>
      <p class="mb-2 text-xs text-base-content/60">
        Tool failure rate this week by role and provider; hover for replies, calls, failed turns and tokens.
      </p>
      <.bar_chart
        :if={not @loading?}
        id="roles-chart"
        chart={@role_chart}
        empty="No agent has made a tool call this week."
      />
      <div data-test="agents" class="mt-6">
        <h3 class="text-xs font-medium text-base-content/70">By agent</h3>
        <p :if={@loading?} data-test="agents-loading" class="text-base-content/60">
          Loading the project's agents...
        </p>
        <p :if={not @loading? and @agent_chart["categories"] == []} class="text-base-content/60">
          No agent has made a tool call yet.
        </p>
        <.paged_chart
          :if={not @loading? and @agent_chart["categories"] != []}
          id="agents-chart"
          chart={@agent_chart}
          page={@agent_page}
          name="agents"
        />
      </div>
    </section>

    <section id="section-qa" data-test="qa" class="mt-8 scroll-mt-4">
      <.heading>QA</.heading>
      <div class="grid gap-6 md:grid-cols-3">
        <div data-test="qa-attempts">
          <Offers.chart
            :if={not @page_loading?}
            agent_id="qa-attempts"
            results={@qa_results}
            title="QA attempts"
            label="QA attempts"
            empty="No QA attempts yet."
            test="qa-results"
          />
        </div>
        <div data-test="teams" class="md:col-span-2">
          <h3 class="text-xs font-medium text-base-content/70">By team</h3>
          <.bar_chart
            :if={not @loading?}
            id="teams-chart"
            chart={@team_chart}
            empty="No team has QA attempts or promotions yet."
          />
        </div>
      </div>
    </section>

    <section id="section-stories" data-test="story-stages" class="mt-8 scroll-mt-4">
      <.heading>Time per story</.heading>
      <p :if={@loading?} data-test="stories-loading" class="text-base-content/60">
        Loading the project's stories...
      </p>
      <p :if={not @loading? and @stage_chart["categories"] == []} class="text-base-content/60">
        No story has been released yet.
      </p>
      <.paged_chart
        :if={not @loading? and @stage_chart["categories"] != []}
        id="story-stages-chart"
        chart={@stage_chart}
        page={@stage_page}
        name="stages"
      />
      <p class="mt-1 text-xs text-base-content/60">
        Stage times are active time; waiting is time blocked on a person. Stages can overlap,
        so a story's bar may run past its total. Hover a story for its QA rounds, waits,
        messages and tokens.
      </p>
    </section>

    <section id="section-blocked" data-test="project-blocked" class="mt-8 scroll-mt-4">
      <.heading>Blocked time</.heading>
      <p :if={@loading?} data-test="project-blocked-loading" class="text-base-content/60">
        Loading...
      </p>
      <div :if={not @loading?} class="grid gap-6 lg:grid-cols-3">
        <div>
          <h3 class="text-xs font-medium text-base-content/70">Hours waiting, by who held it</h3>
          <.bar_chart id="blocked-chart" chart={@blocked_chart} empty="Nothing waited." />
        </div>
        <div>
          <h3 class="text-xs font-medium text-base-content/70">Tap-outs this week, by role</h3>
          <.bar_chart id="tap-outs-chart" chart={@tap_out_chart} empty="No tap-outs this week." />
        </div>
        <div>
          <h3 class="text-xs font-medium text-base-content/70">
            Wait for an answer this week, by who asked
          </h3>
          <.bar_chart id="questions-chart" chart={@question_chart} empty="No questions this week." />
        </div>
      </div>
    </section>

    <section id="section-offers" data-test="offers" class="mt-8 scroll-mt-4">
      <.heading>Offers</.heading>
      <div class="grid gap-6 md:grid-cols-3">
        <div data-test="offer-health">
          <form phx-change="offer_role" data-test="offer-role-filter" class="mb-1">
            <label class="sr-only" for="offer-role">Role</label>
            <select id="offer-role" name="role" class="select select-bordered select-xs">
              <option value="">All roles</option>
              <option
                :for={h <- @summary.offer_health}
                value={h.role}
                selected={h.role == @offer_role}
              >
                {h.role}
              </option>
            </select>
          </form>
          <Offers.chart
            :if={not @page_loading? and not @offer_loading?}
            agent_id={"performance-#{@offer_role || "all"}"}
            results={@offer_results}
          />
          <div
            :if={@offer_loading?}
            data-test="offer-results-loading"
            class="h-36 w-full animate-pulse rounded bg-base-200"
          >
          </div>
          <div
            :for={h <- @summary.offer_health}
            :if={is_nil(@offer_role) or h.role == @offer_role}
            data-test="offer-health-role"
            data-role={h.role}
            class="text-xs text-base-content/70"
          >
            <span>{h.role}</span> -- claim rate {percent(h.claim_rate)}
            <span :if={h.claim_rate != nil}>, ignored {h.ignored}, declined {h.declined}</span>
            <span :if={h.superseded > 0}>, superseded {h.superseded}</span>
          </div>
        </div>
        <div class="md:col-span-2">
          <h3 class="text-xs font-medium text-base-content/70">By kind this week</h3>
          <.bar_chart
            :if={not @loading?}
            id="offer-kinds-chart"
            chart={@offer_kind_chart}
            empty="No offers this week."
          />
        </div>
      </div>
    </section>

    <section id="section-messages" data-test="project-interventions" class="mt-8 scroll-mt-4">
      <.heading>Messages to agents</.heading>
      <p :if={@loading?} data-test="project-interventions-loading" class="text-base-content/60">
        Loading...
      </p>
      <Offers.chart
        :if={not @loading?}
        agent_id="interventions"
        results={@intervention_results}
        title="Messages"
        label="Messages to agents by kind"
        empty="None recorded."
        test="intervention-results"
      />
      <p
        :if={not @loading? and @summary.project_level_interventions != []}
        data-test="project-interventions-summary"
        class="text-sm"
      >
        {length(@summary.project_level_interventions)} at project level, serving no story ({intervention_kind_counts(
          @summary.project_level_interventions
        )})
      </p>
    </section>

    <section id="section-changes" data-test="changes" class="mt-8 scroll-mt-4">
      <.heading>What I'd change first</.heading>
      <Scorecard.changes :if={not @page_loading?} kpis={@scorecard.kpis} />
    </section>

    <section id="section-limits" data-test="limits" class="mt-8 scroll-mt-4">
      <.heading>Limits of this report</.heading>
      <Scorecard.limits />
    </section>
    """
  end

  defp agent_label(agent), do: "#{agent.role} (#{agent.provider})"

  defp kind_label(:message), do: "message"
  defp kind_label(:restart), do: "restart"

  defp intervention_kind_counts(interventions) do
    interventions
    |> Enum.group_by(& &1.kind)
    |> Enum.map(fn {kind, items} -> "#{length(items)} #{kind_label(kind)}" end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  slot :inner_block, required: true

  defp heading(assigns) do
    ~H"""
    <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  attr :id, :string, required: true
  attr :chart, :map, required: true
  attr :empty, :string, required: true

  # A bar chart, or a line saying there is nothing to draw.
  defp bar_chart(assigns) do
    ~H"""
    <p :if={@chart["categories"] == []} class="text-sm text-base-content/60">{@empty}</p>
    <div
      :if={@chart["categories"] != []}
      id={@id}
      data-test={@id}
      phx-hook="EChart"
      phx-update="ignore"
      data-option={Jason.encode!(@chart)}
      style={"width: 100%; height: #{Charts.bars_height(@chart)}px;"}
    >
    </div>
    """
  end

  attr :id, :string, required: true
  attr :chart, :map, required: true
  attr :page, :integer, required: true
  attr :name, :string, required: true

  # A bar chart ten rows at a time. The id carries the page so the hook, which
  # LiveView leaves alone once mounted, draws each page fresh.
  defp paged_chart(assigns) do
    assigns =
      assigns
      |> assign(:shown, Charts.page(assigns.chart, assigns.page))
      |> assign(:pages, Charts.page_count(assigns.chart))

    ~H"""
    <div
      id={"#{@id}-#{@page}"}
      data-test={@id}
      phx-hook="EChart"
      phx-update="ignore"
      data-option={Jason.encode!(@shown)}
      style={"width: 100%; height: #{Charts.bars_height(@shown)}px;"}
    >
    </div>
    <div :if={@pages > 1} data-test={"#{@id}-pager"} class="mt-1 flex items-center gap-2 text-sm">
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="chart_page"
        phx-value-chart={@name}
        phx-value-page={@page - 1}
        disabled={@page == 1}
      >
        Previous
      </button>
      <span class="text-base-content/70">Page {@page} of {@pages}</span>
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="chart_page"
        phx-value-chart={@name}
        phx-value-page={@page + 1}
        disabled={@page == @pages}
      >
        Next
      </button>
    </div>
    """
  end

  defp chart_tokens_label(:unknown), do: "unknown"
  defp chart_tokens_label(total), do: "#{total} tokens"

  defp percent(nil), do: "not yet measured"
  defp percent(rate), do: "#{round(rate * 100)}%"
end
