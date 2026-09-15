defmodule CodeMySpecWeb.DevFreshnessLive do
  @moduledoc """
  Which analyzer has read which files, per working copy, and where it has
  fallen behind.

  ## Why per file, and why this page exists

  Freshness used to be one boolean per source, computed by hashing every file
  that source's roles cover and comparing it to the hash the last completed run
  was stamped with. That answers "has anything changed" and nothing else, and
  for an analyzer slower than the edit rate it is permanently *no*: exunit takes
  about 2m20s here and an agent edits every couple of minutes, so its findings
  were labelled stale forever (7a7eed33). No hashing scheme fixes that — the
  question is wrong.

  `Analysis.Coverage` asks a question that still has a useful answer while the
  corpus moves: which files did this run actually read, and at what content.
  This page is that table made legible.

  ## The three states, which are not two

  A file is **current** (read, and it still holds the bytes that were read),
  **stale** (read, and it has moved since), or **unread** (its role feeds this
  analyzer and no run has ever covered it).

  The third is the one the whole table exists for. `tests_passing` and
  `no_problems` are `count == 0`, so before coverage existed a file nobody had
  analysed and a file with nothing wrong were the same shape — no rows — and
  absence rendered as good news. Unread is shown separately here for that
  reason, and never folded into a count of problems.

  ## Read-only

  Nothing here runs an analyzer or recomputes anything. It reads `file_analyses`
  against `files` and reports the difference.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Analysis.{Coverage, Fingerprint, Run, RunsRepository}
  alias CodeMySpec.DevState
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @refresh_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    projects = projects()
    selected = List.first(projects)

    if connected?(socket), do: schedule_tick()

    {:ok,
     socket
     |> assign(projects: projects, selected: selected, source: "spex", limit: 50)
     |> assign_copies()
     |> assign_report()}
  end

  @impl true
  def handle_event("select_project", %{"project" => id}, socket) do
    selected = Enum.find(socket.assigns.projects, &(&1.id == id))

    {:noreply,
     socket
     |> assign(selected: selected, copy: nil)
     |> assign_copies()
     |> assign_report()}
  end

  def handle_event("select_copy", %{"copy" => id}, socket) do
    copy = Enum.find(socket.assigns.copies, &(&1.id == id))
    {:noreply, socket |> assign(copy: copy) |> assign_report()}
  end

  def handle_event("select_source", %{"source" => source}, socket) do
    {:noreply, socket |> assign(source: source) |> assign_report()}
  end

  def handle_event("recheck", _params, socket), do: {:noreply, assign_report(socket)}

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign_report(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp projects do
    DevState.report().projects
    |> Enum.map(&%{id: &1.project_id, name: &1.name})
    |> Enum.sort_by(& &1.name)
  end

  defp assign_copies(%{assigns: %{selected: nil}} = socket),
    do: assign(socket, copies: [], copy: nil)

  defp assign_copies(%{assigns: %{selected: project}} = socket) do
    copies =
      %Scope{active_project_id: project.id}
      |> WorkingCopies.list_harnesses()
      |> Enum.map(&%{id: &1.id, label: &1.label || &1.root, root: &1.root, main: &1.main})
      |> Enum.sort_by(&{!&1.main, &1.label})

    assign(socket, copies: copies, copy: List.first(copies))
  end

  # Coverage is keyed per checkout, so every question here needs one. A scope
  # without a working copy would read across all of them and report a blend that
  # describes no tree that ever existed.
  defp assign_report(%{assigns: %{selected: nil}} = socket), do: assign(socket, report: nil)
  defp assign_report(%{assigns: %{copy: nil}} = socket), do: assign(socket, report: nil)

  defp assign_report(%{assigns: %{selected: project, copy: copy, source: source}} = socket) do
    scope = %Scope{active_project_id: project.id, active_working_copy_id: copy.id}

    stale = Coverage.stale_report(scope, source)
    unread = Coverage.unanalyzed_files(scope, source)

    assign(socket,
      report: %{
        stale: stale,
        unread: unread,
        fresh?: stale == [] and unread == [],
        roles: Fingerprint.roles(source),
        run: latest_run(scope, source),
        at: DateTime.utc_now()
      }
    )
  end

  # The project-wide answer, beside the per-file one, because the contrast is
  # the point: a single `input_fingerprint` mismatch says the source is stale
  # and cannot say which file did it.
  defp latest_run(scope, source) do
    case RunsRepository.latest_full_runs(scope)[source] do
      %Run{} = run -> %{status: run.status, started_at: run.started_at, id: run.id}
      _ -> nil
    end
  end

  defp short(nil), do: "—"
  defp short(fp) when is_binary(fp), do: String.slice(fp, 0, 10)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-6 space-y-6">
      <header class="space-y-1">
        <h1 class="text-xl font-semibold">Analyzer freshness</h1>
        <p class="text-sm opacity-70">
          What each analyzer has read, per working copy, and where it has fallen behind.
          Read, stale and <em>unread</em> are three different answers — the third is the one
          a problem count cannot give you. Nothing here runs an analyzer.
        </p>
      </header>

      <div class="flex flex-wrap items-end gap-3">
        <form phx-change="select_project" class="flex items-center gap-2">
          <label for="project" class="text-sm opacity-70">Project</label>
          <select id="project" name="project" class="select select-sm select-bordered">
            <option :for={p <- @projects} value={p.id} selected={@selected && p.id == @selected.id}>
              {p.name}
            </option>
          </select>
        </form>

        <form phx-change="select_copy" class="flex items-center gap-2">
          <label for="copy" class="text-sm opacity-70">Working copy</label>
          <select id="copy" name="copy" class="select select-sm select-bordered">
            <option :for={c <- @copies} value={c.id} selected={@copy && c.id == @copy.id}>
              {c.label}{if c.main, do: " (main)", else: ""}
            </option>
          </select>
        </form>

        <form phx-change="select_source" class="flex items-center gap-2">
          <label for="source" class="text-sm opacity-70">Analyzer</label>
          <select id="source" name="source" class="select select-sm select-bordered">
            <option :for={s <- Run.sources()} value={s} selected={s == @source}>{s}</option>
          </select>
        </form>

        <button type="button" phx-click="recheck" class="btn btn-sm">Re-check</button>
      </div>

      <p :if={@copies == []} class="text-sm text-error">
        This project has no working copies, so there is nothing coverage could be keyed to.
      </p>

      <div :if={@report} class="space-y-6">
        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            {@source} on {@copy.label}
          </h2>
          <dl class="grid grid-cols-4 gap-4 text-sm">
            <div>
              <dt class="opacity-60">Verdict</dt>
              <dd class={if @report.fresh?, do: "text-success", else: "text-warning"}>
                {if @report.fresh?, do: "current", else: "behind"}
              </dd>
            </div>
            <div>
              <dt class="opacity-60">Stale</dt>
              <dd class="tabular-nums">{length(@report.stale)}</dd>
            </div>
            <div>
              <dt class="opacity-60">Never read</dt>
              <dd class="tabular-nums">{length(@report.unread)}</dd>
            </div>
            <div>
              <dt class="opacity-60">Latest full run</dt>
              <dd class="tabular-nums">
                {if @report.run, do: "#{@report.run.status} ##{@report.run.id}", else: "none"}
              </dd>
            </div>
          </dl>
          <p class="text-xs opacity-60">
            Roles feeding this analyzer: {Enum.map_join(@report.roles, ", ", &to_string/1)}
          </p>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Stale — read, then changed
          </h2>
          <p :if={@report.stale == []} class="text-sm opacity-70">
            Nothing this analyzer read has moved since it read it.
          </p>
          <div :if={@report.stale != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>File</th>
                  <th>Role</th>
                  <th>Read at content</th>
                  <th>Now</th>
                  <th>Read</th>
                  <th>Run</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- Enum.take(@report.stale, @limit)}>
                  <td class="font-mono text-xs">{s.path}</td>
                  <td class="text-xs opacity-70">{s.role}</td>
                  <td class="font-mono text-xs opacity-70">{short(s.recorded)}</td>
                  <td class="font-mono text-xs">{short(s.current)}</td>
                  <td class="text-xs tabular-nums opacity-70">{s.analyzed_at}</td>
                  <td class="text-xs tabular-nums opacity-70">{s.run_id || "—"}</td>
                </tr>
              </tbody>
            </table>
            <p :if={length(@report.stale) > @limit} class="text-xs opacity-60">
              {length(@report.stale) - @limit} more not shown.
            </p>
          </div>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Never read — no run has covered these
          </h2>
          <p class="text-xs opacity-60">
            Not the same as clean. A verdict of "no problems" over a file nobody analysed is
            absence rendering as good news, which is the reading this table exists to prevent.
          </p>
          <p :if={@report.unread == []} class="text-sm opacity-70">
            Every file whose role feeds {@source} has been read at least once.
          </p>
          <ul :if={@report.unread != []} class="text-xs font-mono space-y-0.5">
            <li :for={f <- Enum.take(@report.unread, @limit)} class="flex gap-3">
              <span class="opacity-70">{f.role}</span>
              <span>{f.path}</span>
            </li>
            <li :if={length(@report.unread) > @limit} class="opacity-60">
              {length(@report.unread) - @limit} more not shown.
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end
end
