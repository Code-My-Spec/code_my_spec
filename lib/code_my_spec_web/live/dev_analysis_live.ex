defmodule CodeMySpecWeb.DevAnalysisLive do
  @moduledoc """
  Live, auto-refreshing view of analysis-run state, merging two sources
  that each know half the truth.

  `CodeMySpec.DevState.report/1` (the database) knows every project, every
  working copy's name and executor, and every row `analysis_runs` currently
  marks `:running` — including its own `started_at`. What it cannot answer
  is the question this dashboard exists for: is a source's rows one real
  execution several requests are tied to, or genuinely more than one thing
  happening at once. Every tied request gets its own row there, so four
  ties on one execution read exactly like four executions.

  The harness's own `CmsHarness.Project.AnalysisServer.status/1` (fetched
  over HTTP from the local harness's `/dashboard-status`, since that state
  lives in that OS process's memory, not the database) answers that: one
  running entry per project, with its `tied_run_ids`, and the queue behind
  it. This view merges the two — the harness for which run_ids are riding
  on which execution, the database for when each of those run_ids was
  actually asked for.

  Built to answer, at a glance, the two things this session spent hours
  reconstructing by hand from `curl` and log greps: is any working copy's
  queue past the "current run, next run" ceiling per source (story 839's
  own domain rule — more than one *execution* queued behind the running one
  for a source is a bug, not backlog — counting requesters instead of
  executions is exactly the mistake this view's first draft made), and
  which real caller each row actually is.

  Polls both sources on a timer rather than subscribing to anything — there
  is no PubSub broadcast on analysis-run state today, and this exists to
  see what already happens, not to add a new write path during an active
  investigation. The harness fetch is local-only (`http://localhost:4004`)
  by design: this box runs one harness serving every working copy on it,
  and reaching a genuinely remote harness would need an address this
  dashboard has no way to look up today — degrades to the database-only
  view (a `harness_unreachable` note per project) rather than failing the
  whole page when that HTTP call cannot complete.

  Dev-only (`:dev_routes`) and deliberately not linked from `/app` nav: this
  reads across every project on the box, which is exactly the boundary the
  rest of the app is built to respect.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.DevState

  @refresh_ms 2_000
  @harness_base_url "http://localhost:4004"
  @harness_fetch_timeout 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_tick()

    {:ok, assign(socket, refresh_ms: @refresh_ms) |> assign_state()}
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign_state(socket)}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp assign_state(socket) do
    report = DevState.report()
    harness = fetch_harness_status()

    assign(socket,
      report: report,
      harness_error: harness_error(harness),
      rows: Enum.flat_map(report.projects, &copy_rows(&1, harness))
    )
  end

  # --- Fetching the harness's own view ---

  defp fetch_harness_status do
    case Req.get(@harness_base_url <> "/dashboard-status", request_options()) do
      {:ok, %{status: 200, body: body}} -> {:ok, index_by_root(body)}
      {:ok, %{status: status}} -> {:error, "harness answered #{status}"}
      {:error, reason} -> {:error, "harness_unreachable: #{inspect(reason)}"}
    end
  end

  # The timeout, plus whatever the environment pins in front of the client.
  #
  # `:dev_routes` is true in `config/test.exs`, so this LiveView's route exists
  # in the test router and a test that mounts it would really call :4004 — the
  # live harness on the developer's own box, not a fake the test started. That
  # is the whole of what `http_clients_are_stubbable_test` guards against, and
  # the reason it refused this module: a bare `Req.get/2` has nowhere for
  # `{Req.Test, __MODULE__}` to attach.
  #
  # Merging config rather than adding to `@allowed` because this genuinely can
  # be pinned, and the `:loopback` entries there mean something narrower — a
  # FakeUpstream or a container the test starts itself, where there is no real
  # service to reach by accident.
  defp request_options do
    Keyword.merge(
      [receive_timeout: @harness_fetch_timeout],
      Application.get_env(:code_my_spec, __MODULE__, [])
    )
  end

  defp index_by_root(%{"projects" => projects}) do
    Map.new(projects, &{&1["root"], &1["queue"]})
  end

  defp index_by_root(_body), do: %{}

  defp harness_error({:error, reason}), do: reason
  defp harness_error({:ok, _}), do: nil

  # --- Building rows ---

  # One row per *execution* — the running one and each queued one, not per
  # source and not per requester. A source queued more than once behind the
  # running one is exactly the violation to see, and it shows as two rows
  # naming the same source rather than one row with an inflated count.
  defp copy_rows(project, harness) do
    for copy <- project.working_copies do
      db_rows_by_id = Map.new(copy.runs_claiming_running, &{&1.id, &1})

      case queue_for(harness, copy.root) do
        {:ok, queue} ->
          executions(queue)
          |> Enum.map(&build_row(project, copy, &1, db_rows_by_id))

        {:error, reason} ->
          orphan_rows(project, copy, reason)
      end
    end
    |> List.flatten()
    |> Enum.sort_by(&{&1.status != :running, &1.project_name, &1.root, &1.source})
  end

  defp queue_for({:ok, by_root}, root) do
    case Map.fetch(by_root, root) do
      {:ok, queue} -> {:ok, queue}
      :error -> {:ok, %{"running" => nil, "queued" => []}}
    end
  end

  defp queue_for({:error, reason}, _root), do: {:error, reason}

  defp executions(queue) do
    running = queue["running"] && [{:running, queue["running"]}]
    queued = Enum.map(queue["queued"] || [], &{:queued, &1})
    List.wrap(running) ++ queued
  end

  defp build_row(project, copy, {status, execution}, db_rows_by_id) do
    tied_ids = execution["tied_run_ids"] || []
    all_ids = [execution["run_id"] | tied_ids]

    %{
      project_name: project.name,
      root: copy.root,
      executor: copy.executor,
      source: execution["source"],
      status: status,
      primary_id: execution["run_id"],
      requesters: Enum.map(all_ids, &requester(&1, db_rows_by_id)),
      no_db_row_ids: Enum.reject(all_ids, &Map.has_key?(db_rows_by_id, &1))
    }
  end

  defp requester(run_id, db_rows_by_id) do
    %{id: run_id, started_at: db_rows_by_id[run_id] && db_rows_by_id[run_id].started_at}
  end

  # The harness could not be asked at all — say so per copy that has
  # anything claimed running, rather than lose the database's own view of
  # it. `status: :unknown` so it renders distinctly from a confirmed running
  # or queued execution: this is "the ledger says something, the harness
  # would not answer," not "confirmed."
  defp orphan_rows(project, copy, reason) do
    for {source, runs} <- Enum.group_by(copy.runs_claiming_running, & &1.source), runs != [] do
      %{
        project_name: project.name,
        root: copy.root,
        executor: copy.executor,
        source: source,
        status: :unknown,
        primary_id: nil,
        requesters: Enum.map(runs, &%{id: &1.id, started_at: &1.started_at}),
        no_db_row_ids: [],
        harness_reason: reason
      }
    end
  end

  # --- View helpers ---

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

  defp age_seconds(%DateTime{} = started_at),
    do: DateTime.diff(DateTime.utc_now(), started_at, :second)

  defp age_seconds(nil), do: nil

  defp status_badge(:running), do: {"running", "badge-success"}
  defp status_badge(:queued), do: {"queued", "badge-warning"}
  defp status_badge(:unknown), do: {"unconfirmed", "badge-ghost"}

  # More than one *execution* (a row) for the same source on the same
  # working copy is the actual violation — story 839's ceiling is about
  # executions, not about how many requesters are tied to them.
  defp source_over_ceiling?(rows, row) do
    rows
    |> Enum.count(&(&1.root == row.root and &1.source == row.source and &1.status != :unknown))
    |> Kernel.>(2)
  end

  defp row_class(rows, row) do
    if source_over_ceiling?(rows, row), do: "bg-error/10", else: ""
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-6xl mx-auto">
      <div class="mb-6 flex items-baseline justify-between">
        <div>
          <h1 class="text-3xl font-bold">Analysis Runs</h1>
          <p class="text-base-content/60 mt-1">
            Refreshing every {div(@refresh_ms, 1000)}s. One row per execution
            (running or queued), not per requester — more than one queued
            execution for the same source on the same working copy is over
            story 839's "current run, next run" ceiling, a bug rather than
            backlog. Run ids under "requesters" are every id tied to that
            one execution, each with when the database says it was asked
            for.
          </p>
        </div>
        <div class="text-xs text-base-content/50 font-mono text-right">
          checked_at {@report.checked_at}
          <div :if={@harness_error} class="text-warning">harness: {@harness_error}</div>
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
              <th>Source</th>
              <th>Status</th>
              <th>Primary run</th>
              <th>Requesters (run_id @ asked)</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class={row_class(@rows, row)} data-test="analysis-run-row">
              <td class="text-sm">{row.project_name}</td>
              <td class="font-mono text-xs max-w-xs truncate" title={row.root}>{tail(row.root)}</td>
              <td class="font-mono text-xs">{row.source}</td>
              <td>
                <% {label, class} = status_badge(row.status) %>
                <span class={"badge badge-sm #{class}"} title={Map.get(row, :harness_reason)}>
                  {label}
                </span>
              </td>
              <td class="font-mono text-xs">{row.primary_id || "—"}</td>
              <td class="font-mono text-xs opacity-80">
                <div :for={r <- row.requesters} class="whitespace-nowrap">
                  {r.id}{if r.id in row.no_db_row_ids, do: " (no db row)"}
                  <span :if={r.started_at} class="opacity-60">
                    @ {age_seconds(r.started_at)}s ago
                  </span>
                </div>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="6" class="text-center opacity-60 py-8" data-test="analysis-runs-empty">
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
