defmodule CodeMySpecWeb.DevAnalysisLive do
  @moduledoc """
  Live, auto-refreshing view of `CodeMySpec.DevState.report/1` — every
  project, every working copy, what the ledger believes is running or
  queued per analyzer source, and where that disagrees with the runtime.

  Built to answer, at a glance, the two things this session spent hours
  reconstructing by hand from `curl localhost:4000/dev/state | jq` and log
  greps: is any working copy's queue past the "current run, next run"
  ceiling per source (story 839's own domain rule — more than 2 entries for
  one source on one copy is a bug, not backlog), and does the DB's belief
  about what's `:running` match anything actually executing.

  Read-only, polling `DevState.report/1` on a timer rather than subscribing
  to anything — there is no PubSub broadcast on analysis-run state today,
  and this exists to see what already happens, not to add a new write path
  during an active investigation.

  Dev-only (`:dev_routes`) and deliberately not linked from `/app` nav: this
  reads across every project on the box, which is exactly the boundary the
  rest of the app is built to respect.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.DevState

  @refresh_ms 2_000
  # Story 839, John 2026-09-13: one source on one working copy never needs
  # more than two entries — the one running, and the one it is tied to next.
  @max_healthy_per_source 2

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    socket =
      socket
      |> assign(refresh_ms: @refresh_ms, max_healthy_per_source: @max_healthy_per_source)
      |> assign_report()

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign_report(socket)}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp assign_report(socket) do
    report = DevState.report()
    assign(socket, report: report, rows: Enum.flat_map(report.projects, &copy_rows/1))
  end

  # One row per (working copy, source) — the grain the health check is about.
  # A copy with nothing running or queued for a source gets no row; the
  # dashboard is about what is happening, not a matrix of what could be.
  defp copy_rows(project) do
    for copy <- project.working_copies,
        {source, runs} <- Enum.group_by(copy.runs_claiming_running, & &1.source),
        runs != [] do
      %{
        project_name: project.name,
        root: copy.root,
        executor: copy.executor,
        source: source,
        count: length(runs),
        oldest_started_at: runs |> Enum.map(& &1.started_at) |> Enum.min(DateTime),
        run_ids: Enum.map(runs, & &1.id) |> Enum.sort()
      }
    end
    |> Enum.sort_by(&{&1.count, &1.project_name, &1.root, &1.source}, :desc)
  end

  # Every root on this box shares the same long prefix
  # (/Users/.../code_my_spec/.claude/worktrees/...) — the part that tells one
  # row apart from another is the end, and CSS `truncate` cuts there instead
  # of at the front. Truncating the string itself, keeping the tail, is what
  # actually shows the worktree name at a glance.
  @root_tail_chars 40

  defp tail(root) when byte_size(root) > @root_tail_chars do
    "…" <> String.slice(root, -@root_tail_chars, @root_tail_chars)
  end

  defp tail(root), do: root

  defp age_seconds(%DateTime{} = started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end

  defp row_class(%{count: count}) when count > @max_healthy_per_source, do: "bg-error/10"
  defp row_class(_row), do: ""

  defp count_badge_class(count) when count > @max_healthy_per_source, do: "badge-error"
  defp count_badge_class(_count), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-6xl mx-auto">
      <div class="mb-6 flex items-baseline justify-between">
        <div>
          <h1 class="text-3xl font-bold">Analysis Runs</h1>
          <p class="text-base-content/60 mt-1">
            Live from <code class="text-xs">DevState.report/1</code>,
            refreshing every {div(@refresh_ms, 1000)}s. A source with more than
            {@max_healthy_per_source} entries on one working copy is over the
            "current run, next run" ceiling — a bug, not a busy box.
          </p>
        </div>
        <div class="text-xs text-base-content/50 font-mono">
          checked_at {@report.checked_at}
        </div>
      </div>

      <div :if={@report.disagreements != []} class="alert alert-warning mb-6" role="alert">
        <div>
          <h3 class="font-bold">Disagreements ({length(@report.disagreements)})</h3>
          <ul class="list-disc list-inside text-sm mt-1">
            <li :for={d <- @report.disagreements}>{d}</li>
          </ul>
        </div>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-zebra table-sm" data-test="analysis-runs-table">
          <thead>
            <tr>
              <th>Project</th>
              <th>Working copy</th>
              <th>Executor</th>
              <th>Source</th>
              <th>Count</th>
              <th>Oldest started</th>
              <th>Run ids</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class={row_class(row)} data-test="analysis-run-row">
              <td class="text-sm">{row.project_name}</td>
              <td class="font-mono text-xs max-w-xs truncate" title={row.root}>{tail(row.root)}</td>
              <td class="text-xs">
                <span :if={row.executor.held} class="badge badge-success badge-sm">
                  held
                </span>
                <span :if={!row.executor.held} class="badge badge-error badge-sm">
                  unheld
                </span>
              </td>
              <td class="font-mono text-xs">{row.source}</td>
              <td>
                <span class={"badge badge-sm #{count_badge_class(row.count)}"}>
                  {row.count}
                </span>
              </td>
              <td class="text-xs">{age_seconds(row.oldest_started_at)}s ago</td>
              <td class="font-mono text-xs opacity-70">{Enum.join(row.run_ids, ", ")}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="7" class="text-center opacity-60 py-8" data-test="analysis-runs-empty">
                Nothing running or queued anywhere right now.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
