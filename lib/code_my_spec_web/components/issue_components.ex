defmodule CodeMySpecWeb.IssueComponents do
  @moduledoc """
  An issue, at the grains a page needs: a full card for the issues page, a
  compact row for a list in a modal, its dates, its detail, and a modal that
  holds a list and the detail of one picked from it.
  """
  use CodeMySpecWeb, :html

  import CodeMySpecWeb.Markdown, only: [md_html: 1]

  alias CodeMySpecWeb.IssueCharts

  @doc "One issue on the issues page: title, description, badges and dates."
  attr :issue, :map, required: true
  attr :href, :string, required: true
  attr :story_number, :integer, default: nil

  def issue_card(assigns) do
    ~H"""
    <div
      id={"issue-#{@issue.id}"}
      class="card bg-base-100 shadow-md cursor-pointer hover:shadow-lg transition-shadow"
      phx-click={JS.navigate(@href)}
    >
      <div class="card-body py-4">
        <div class="flex items-start justify-between gap-4">
          <div class="flex-1 min-w-0">
            <h2 class="card-title text-base">{@issue.title}</h2>
            <p class="text-sm text-base-content/70 mt-1 line-clamp-2">{@issue.description}</p>
          </div>
          <.issue_badges issue={@issue} class="shrink-0" />
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/50">
          <.issue_dates issue={@issue} />
          <span :if={@story_number}>Story #{@story_number}</span>
          <span :if={@issue.scope != :app} class="badge badge-xs badge-outline">{@issue.scope}</span>
        </div>
      </div>
    </div>
    """
  end

  @doc "One issue as a compact row; clicking it pushes `on_pick` with its id."
  attr :issue, :map, required: true
  attr :on_pick, :string, required: true
  attr :target, :any, default: nil

  def issue_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_pick}
      phx-value-id={@issue.id}
      phx-target={@target}
      data-test="issue-row"
      data-issue-id={@issue.id}
      class="flex w-full items-center gap-3 rounded-box px-2 py-2 text-left hover:bg-base-200"
    >
      <span class="min-w-0 flex-1 truncate text-sm">{@issue.title}</span>
      <span class="hidden shrink-0 text-xs opacity-50 sm:inline">{day(@issue.inserted_at)}</span>
      <.issue_badges issue={@issue} class="shrink-0" />
    </button>
    """
  end

  @doc "Its severity and status, as badges."
  attr :issue, :map, required: true
  attr :class, :any, default: nil

  def issue_badges(assigns) do
    ~H"""
    <div class={["flex items-center gap-1.5", @class]}>
      <span class={["badge badge-sm", severity_class(@issue.severity)]}>{@issue.severity}</span>
      <span class={["badge badge-sm", status_class(@issue.status)]}>{@issue.status}</span>
    </div>
    """
  end

  @doc "When it was created, accepted, closed and last updated — each that it has."
  attr :issue, :map, required: true

  def issue_dates(assigns) do
    ~H"""
    <span data-test="issue-created">Created {day(@issue.inserted_at)}</span>
    <span :if={@issue.accepted_at} data-test="issue-accepted">Accepted {day(@issue.accepted_at)}</span>
    <span :if={@issue.closed_at} data-test="issue-closed">Closed {day(@issue.closed_at)}</span>
    <span data-test="issue-updated">Updated {day(@issue.updated_at)}</span>
    """
  end

  @doc "One issue in full: title, badges, dates, description and resolution."
  attr :issue, :map, required: true

  def issue_detail(assigns) do
    ~H"""
    <div data-test="issue-detail" data-issue-id={@issue.id}>
      <p class="text-xs uppercase tracking-wide opacity-60">Issue {String.slice(@issue.id, 0, 8)}</p>
      <h2 class="mt-1 pr-8 text-lg font-semibold text-balance">{@issue.title}</h2>
      <.issue_badges issue={@issue} class="mt-2" />
      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs opacity-60">
        <.issue_dates issue={@issue} />
      </div>
      <div class="prose prose-sm mt-3 max-w-none prose-p:my-1.5 prose-ul:my-1.5 prose-ol:my-1.5 prose-pre:my-2 prose-headings:mt-4 prose-headings:mb-1">
        {md_html(@issue.description)}
      </div>
      <div :if={@issue.resolution} class="mt-4">
        <h3 class="text-sm font-semibold">Resolution</h3>
        <div class="prose prose-sm mt-1 max-w-none prose-p:my-1.5 prose-ul:my-1.5 prose-ol:my-1.5 prose-pre:my-2">
          {md_html(@issue.resolution)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Issues over whatever page is open: the list, or one picked from it with the
  way back. `picked` is nil for the list. Pushes `on_pick` (with `id`),
  `on_back` and `on_close`.
  """
  attr :issues, :list, required: true
  attr :total, :integer, required: true
  attr :picked, :map, default: nil
  attr :project_id, :string, required: true
  attr :on_pick, :string, required: true
  attr :on_back, :string, required: true
  attr :on_close, :string, required: true
  attr :chart_issues, :list, default: [], doc: "every issue, for the chart"
  attr :chart_range, :string, default: "30d"
  attr :chart_view, :string, default: "status"
  attr :on_chart, :string, default: nil, doc: "pushed with `range` or `view`; no chart without it"

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="issues-modal"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="modal-box w-11/12 max-w-3xl space-y-3">
        <button
          type="button"
          phx-click={@on_close}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>

        <div :if={is_nil(@picked)} class="space-y-2">
          <div class="flex items-baseline gap-2 pr-8">
            <h2 class="text-lg font-semibold">Issues</h2>
            <span class="text-xs opacity-60">open · high and medium · app · newest first</span>
          </div>
          <IssueCharts.open_over_time
            :if={@on_chart}
            issues={@chart_issues}
            range={@chart_range}
            view={@chart_view}
            event={@on_chart}
            height={160}
          />
          <p :if={@issues == []} class="py-6 text-center text-sm opacity-60">No open issues.</p>
          <div class="max-h-[60dvh] divide-y divide-base-200 overflow-y-auto">
            <.issue_row :for={issue <- @issues} issue={issue} on_pick={@on_pick} />
          </div>
          <div class="flex items-center justify-between">
            <span :if={@total > length(@issues)} class="text-xs opacity-60">
              Showing {length(@issues)} of {@total}
            </span>
            <.link
              navigate={~p"/app/projects/#{@project_id}/issues"}
              data-test="issues-modal-all"
              class="btn btn-sm btn-ghost ml-auto"
            >
              View all issues <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.link>
          </div>
        </div>

        <div :if={@picked} class="space-y-3">
          <button
            type="button"
            phx-click={@on_back}
            data-test="issues-modal-back"
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-arrow-left" class="size-3" /> Issues
          </button>
          <div class="max-h-[60dvh] overflow-y-auto">
            <.issue_detail issue={@picked} />
          </div>
          <div class="flex justify-end">
            <.link
              navigate={~p"/app/projects/#{@project_id}/issues/#{@picked.id}"}
              class="btn btn-sm btn-ghost"
            >
              View full issue <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.link>
          </div>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_close} aria-label="Close"></button>
    </div>
    """
  end

  @doc "A date the way the issue views print one."
  def day(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y")
  def day(_at), do: "—"

  defp severity_class(:critical), do: "badge-error"
  defp severity_class(:high), do: "badge-warning"
  defp severity_class(:medium), do: "badge-info"
  defp severity_class(_low_or_info), do: "badge-ghost"

  defp status_class(:incoming), do: "badge-warning badge-outline"
  defp status_class(:accepted), do: "badge-info badge-outline"
  defp status_class(:resolved), do: "badge-success badge-outline"
  defp status_class(_dismissed), do: "badge-ghost"
end
