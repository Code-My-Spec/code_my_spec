defmodule CodeMySpecWeb.IssuesLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Issues
  alias CodeMySpec.Stories
  alias CodeMySpecWeb.IssueCharts

  # Status and severity are each a set to show. Incoming and accepted — open —
  # by default; high and medium by default, since below is noise somebody looks
  # at on purpose.
  @statuses ~w(incoming accepted resolved dismissed)
  @default_statuses ~w(incoming accepted)
  @status_order [:incoming, :accepted, :dismissed, :resolved]
  @severities ~w(critical high medium low info)
  @default_severities ~w(high medium)
  # The local index this view replaced could filter by scope; the cloud one
  # could not, so the merge quietly dropped it. Restored here rather than
  # left as a capability the move cost us.
  @scopes ~w(all app qa docs framework)

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Issues
      <:actions>
        <form id="issues-filter" phx-change="filter" class="flex flex-wrap items-center gap-2">
          <.multi_select
            name="status"
            label="Status"
            options={@status_options}
            chosen={@filter_status}
          />
          <.multi_select
            name="severity"
            label="Severity"
            options={@severity_options}
            chosen={@filter_severity}
          />
          <select class="select select-sm select-bordered" name="scope">
            <option :for={s <- @scope_options} value={s} selected={s == @filter_scope}>
              {String.capitalize(s)}
            </option>
          </select>
        </form>
      </:actions>
    </.header>

    <div class="mt-6">
      <IssueCharts.open_over_time issues={@chart_issues} range={@range} view={@chart} event="chart" />
    </div>

    <div :if={@issues == []} class="text-center py-12 text-base-content/60">
      No issues found.
    </div>

    <div id="issues" class="space-y-4 mt-6">
      <section
        :for={{status, issues} <- @groups}
        id={"issues-#{status}"}
        data-test="issue-group"
        data-status={status}
        class="space-y-4"
      >
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
          {status} <span class="font-normal">({length(issues)})</span>
        </h2>
        <div
          :for={issue <- issues}
          id={"issue-#{issue.id}"}
          class="card bg-base-100 shadow-md cursor-pointer hover:shadow-lg transition-shadow"
          phx-click={JS.navigate(path(@socket, ~p"/app/projects/#{@project.id}/issues/#{issue.id}"))}
        >
          <div class="card-body py-4">
            <div class="flex items-start justify-between gap-4">
              <div class="flex-1 min-w-0">
                <h2 class="card-title text-base">{issue.title}</h2>
                <p class="text-sm text-base-content/70 mt-1 line-clamp-2">
                  {issue.description}
                </p>
              </div>
              <div class="flex items-center gap-2 shrink-0">
                <.badge color={severity_color(issue.severity)}>
                  {issue.severity}
                </.badge>
                <.badge color={status_color(issue.status)}>
                  {issue.status}
                </.badge>
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-2 text-xs text-base-content/50">
              <span data-test="issue-created">Created {day(issue.inserted_at)}</span>
              <span :if={issue.accepted_at} data-test="issue-accepted">
                Accepted {day(issue.accepted_at)}
              </span>
              <span :if={issue.closed_at} data-test="issue-closed">
                Closed {day(issue.closed_at)}
              </span>
              <span data-test="issue-updated">Updated {day(issue.updated_at)}</span>
              <span :if={issue.story_id}>Story #{@story_numbers[issue.story_id]}</span>
              <span :if={issue.scope != :app} class="badge badge-xs badge-outline">
                {issue.scope}
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :chosen, :list, required: true

  # A dropdown of checkboxes. The empty hidden value is what lets every box be
  # cleared: without it an all-unchecked form sends nothing, and nothing reads
  # as the default.
  defp multi_select(assigns) do
    ~H"""
    <div class="dropdown dropdown-end" data-test={"filter-#{@name}"}>
      <div
        tabindex="0"
        role="button"
        class="btn btn-sm btn-outline shrink-0 whitespace-nowrap font-normal"
      >
        {summary(@chosen, @options, @label)}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu z-10 mt-1 w-44 rounded-box border border-base-300 bg-base-100 p-2 shadow"
      >
        <input type="hidden" name={"#{@name}[]"} value="" />
        <li :for={option <- @options}>
          <label class="flex items-center gap-2">
            <input
              type="checkbox"
              name={"#{@name}[]"}
              value={option}
              checked={option in @chosen}
              class="checkbox checkbox-xs"
            />
            {String.capitalize(option)}
          </label>
        </li>
      </ul>
    </div>
    """
  end

  # Short enough for the header: one choice by name, several as the first and
  # a count. `label` stands in for the field when the choice says nothing.
  defp summary(chosen, options, label) when length(chosen) == length(options),
    do: "All #{String.downcase(label)}"

  defp summary([], _options, label), do: "No #{String.downcase(label)}"
  defp summary([one], _options, _label), do: String.capitalize(one)

  defp summary([first | rest], _options, _label),
    do: "#{String.capitalize(first)} +#{length(rest)}"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Issues.subscribe(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:section, :issues)
     |> assign(:page_title, "Issues")
     |> assign(:filter_status, @default_statuses)
     |> assign(:filter_severity, @default_severities)
     |> assign(:filter_scope, "all")
     |> assign(:range, "30d")
     |> assign(:chart, "status")
     |> assign(:status_options, @statuses)
     |> assign(:scope_options, @scopes)
     |> assign(:severity_options, @severities)}
  end

  # Filters live in the query string, not just in assigns — a filtered list is
  # then a link you can send someone, and it survives a reload. A filter left
  # out of the URL is at its default (the patch drops defaults), not at
  # whatever was showing before.
  @impl true
  def handle_params(params, _uri, %{assigns: %{scope: %{}}} = socket) do
    {:noreply,
     socket
     |> assign(:filter_status, set_param(params["status"], @statuses, @default_statuses))
     |> assign(:filter_severity, set_param(params["severity"], @severities, @default_severities))
     |> assign(:filter_scope, param(params["scope"], @scopes, "all"))
     |> assign(:range, param(params["range"], IssueCharts.ranges(), "30d"))
     |> assign(:chart, param(params["chart"], IssueCharts.views(), "status"))
     |> load_issues()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp param(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp param(_value, _allowed, fallback), do: fallback

  # A list in the URL (`severity[]=high&severity[]=medium`); "none" for an
  # empty set, which is a choice and not the absence of one.
  defp set_param("none", _allowed, _default), do: []

  defp set_param(value, allowed, default) when is_binary(value),
    do: set_param([value], allowed, default)

  defp set_param(values, allowed, default) when is_list(values) do
    case Enum.filter(allowed, &(&1 in values)) do
      [] -> default
      chosen -> chosen
    end
  end

  defp set_param(_value, _allowed, default), do: default

  @impl true
  def handle_event("filter", params, socket) do
    a = socket.assigns

    {:noreply,
     patch(socket,
       status: chosen(params["status"], @statuses) || a.filter_status,
       severity: chosen(params["severity"], @severities) || a.filter_severity,
       scope: params["scope"] || a.filter_scope,
       range: a.range,
       chart: a.chart
     )}
  end

  # The chart's range or view; the rest of the query stays as it is.
  def handle_event("chart", params, socket) do
    a = socket.assigns

    {:noreply,
     patch(socket,
       status: a.filter_status,
       severity: a.filter_severity,
       scope: a.filter_scope,
       range: params["range"] || a.range,
       chart: params["view"] || a.chart
     )}
  end

  defp chosen(nil, _allowed), do: nil
  defp chosen(value, allowed) when is_binary(value), do: chosen([value], allowed)
  defp chosen(values, allowed) when is_list(values), do: Enum.filter(allowed, &(&1 in values))

  defp patch(socket, query) do
    # The two sets always travel, defaults included, so a link always says what
    # it shows; the single values only when they are not the default.
    query =
      query
      |> Enum.reject(fn {key, value} -> not is_list(value) and value == default(key) end)
      |> Enum.map(fn
        {key, []} -> {key, "none"}
        pair -> pair
      end)

    push_patch(socket, to: path(socket, ~p"/app/projects/#{socket.assigns.slug}/issues?#{query}"))
  end

  defp default(:range), do: "30d"
  defp default(:chart), do: "status"
  defp default(_key), do: "all"

  @impl true
  def handle_info({_action, %Issues.Issue{}}, socket) do
    {:noreply, load_issues(socket)}
  end

  defp load_issues(socket) do
    scope = socket.assigns.current_scope
    statuses = Enum.map(socket.assigns.filter_status, &String.to_existing_atom/1)
    severities = Enum.map(socket.assigns.filter_severity, &String.to_existing_atom/1)

    filters =
      if socket.assigns.filter_scope == "all",
        do: %{},
        else: %{scope: String.to_existing_atom(socket.assigns.filter_scope)}

    issues =
      scope
      |> Issues.list_filtered(filters)
      |> Enum.filter(&(&1.status in statuses and &1.severity in severities))
      |> Enum.sort_by(&{status_rank(&1.status), -DateTime.to_unix(&1.inserted_at, :microsecond)})

    socket
    |> assign(:issues, issues)
    # Every issue, whatever the filters: the chart is the project's issues
    # over time.
    |> assign(:chart_issues, Issues.list_filtered(scope, %{}))
    |> assign(:groups, Enum.chunk_by(issues, & &1.status) |> Enum.map(&{hd(&1).status, &1}))
    |> assign(:story_numbers, story_numbers(scope))
  end

  defp status_rank(status),
    do: Enum.find_index(@status_order, &(&1 == status)) || length(@status_order)

  # `%{story_id => number}`, so an issue's story is labelled the way the story's
  # own page labels it.
  #
  # A story carries both, and the number is the one that names its spex
  # directory — id 1031 is number 1065, living in `test/spex/1065_…/`. The two
  # coincide on a young project and diverge later (1ab62ffd). `issues.story_id`
  # is a plain integer column with no association, so there is nothing to
  # preload and the number has to be looked up.
  #
  # One query for the project rather than one per issue: this is an admin list
  # that already loads every matching issue, and a per-row lookup would be an
  # N+1 for a label. `Stories.story_numbers/1` rather than
  # `list_project_stories/1`, which would preload `:criteria` and `:tags` for
  # the whole project to hand back two integers per row.
  defp story_numbers(scope), do: Stories.story_numbers(scope)

  defp day(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y")
  defp day(_at), do: "—"

  defp severity_color(:critical), do: "error"
  defp severity_color(:high), do: "warning"
  defp severity_color(:medium), do: "info"
  defp severity_color(:low), do: "ghost"
  defp severity_color(:info), do: "ghost"
  defp severity_color(_), do: "ghost"

  defp status_color(:incoming), do: "warning"
  defp status_color(:accepted), do: "info"
  defp status_color(:resolved), do: "success"
  defp status_color(:dismissed), do: "ghost"
  defp status_color(_), do: "ghost"
end
