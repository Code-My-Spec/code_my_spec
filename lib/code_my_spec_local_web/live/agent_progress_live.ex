defmodule CodeMySpecLocalWeb.AgentProgressLive do
  @moduledoc """
  Story 813 — the non-technical user's live spectator screen.

  Left rail: the project-level requirement milestones with status. Center:
  one vertical timeline per session, most-recently-updated first. The
  active session — the most recently updated one, if updated within the
  live window — has its current step auto-expanded: the last task that
  isn't completed or cancelled. That step shows its artifact plus
  plain-language help (curated body + video for major task types via
  `CodeMySpec.TaskHelp`, a generic explanation otherwise). The user can
  expand any task to override the auto-focus.

  Liveness is recency-based: the PostToolUse hook touches the session's
  `updated_at` on every tool call (`Sessions.touch_session/2`), so "active"
  is simply "updated in the last few minutes" — known on load, no polling
  or timer. Persisted task `status` is not trusted as a live signal (a
  crashed agent leaves stale `:active` tasks behind).

  Filtering keeps the timeline readable: sessions with no activity
  (start == last-updated) and sessions with no tasks are hidden, and the
  list is capped at the ten most recent.

  Live updates: subscribes to the project's sessions PubSub topic so a
  new or advancing task re-renders without a refresh.

  Contract source of truth: the BDD spex suite at `test/spex/813_*`.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.TaskHelp
  alias CodeMySpec.Users.Scope

  # Most recent sessions shown on the timeline.
  @session_cap 10

  # A session reads as "active" if its last activity is within this window.
  # The PostToolUse hook touches updated_at on every tool call.
  @active_window_seconds 300

  # Past this many tasks, collapse the middle of a session's timeline to
  # the newest two + oldest two with an expandable "… N more" in between.
  @task_collapse_threshold 10
  @task_head 2
  @task_tail 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       projects: Projects.list_local_projects(),
       project: nil,
       scope: nil,
       requirements: [],
       sessions: [],
       active_session_id: nil,
       focused_task_id: nil,
       focused_override: nil,
       focused_help: nil,
       focused_requirement: nil,
       expanded_sessions: MapSet.new(),
       requirements_loading: false,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      if connected?(socket), do: Sessions.subscribe_sessions(scope)

      {:noreply,
       socket
       |> assign(
         project: project,
         scope: scope,
         page_title: "#{project.name} — Progress",
         error: nil
       )
       |> recompute_all()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  # A new or advancing task: reload sessions and refocus, but skip the
  # expensive requirement-graph recompute — task lifecycle doesn't change
  # requirement satisfaction. Drop any manual override so focus snaps back.
  @impl true
  def handle_info({:session_changed, _session}, socket) do
    {:noreply, socket |> assign(focused_override: nil) |> recompute_sessions()}
  end

  def handle_info(_msg, socket), do: {:noreply, recompute_all(socket)}

  @impl true
  def handle_event("focus_task", %{"id" => task_id}, socket) do
    {:noreply, socket |> assign(focused_override: task_id) |> refresh_focus()}
  end

  def handle_event("toggle_session_tasks", %{"id" => session_id}, socket) do
    {:noreply, assign(socket, expanded_sessions: toggle(socket.assigns.expanded_sessions, session_id))}
  end

  @impl true
  def handle_async(:requirements, {:ok, requirements}, socket) do
    {:noreply, assign(socket, requirements: requirements, requirements_loading: false)}
  end

  def handle_async(:requirements, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, requirements_loading: false)}

  # -- Recompute -----------------------------------------------------------

  # Full recompute: the expensive requirement-graph rail + sessions + focus.
  # Only on mount and graph-affecting events — never on a heartbeat.
  defp recompute_all(%{assigns: %{scope: nil}} = socket), do: socket

  defp recompute_all(socket),
    do: socket |> assign_sessions() |> refresh_focus() |> load_requirements_async()

  # Sessions + focus only — keeps the already-computed requirement rail.
  defp recompute_sessions(%{assigns: %{scope: nil}} = socket), do: socket
  defp recompute_sessions(socket), do: socket |> assign_sessions() |> refresh_focus()

  # The rail is the expensive part (compute_all + next_actionable over the
  # whole project), so load it off the LiveView process: the page renders
  # sessions immediately and the rail fills in when ready.
  defp load_requirements_async(%{assigns: %{scope: scope, project: project}} = socket) do
    case connected?(socket) do
      true ->
        socket
        |> assign(requirements_loading: true)
        |> start_async(:requirements, fn -> compute_requirements(scope, project) end)

      false ->
        socket
    end
  end

  defp compute_requirements(scope, project) do
    actionable_keys =
      scope |> RequirementGraph.next_actionable() |> MapSet.new(&requirement_key/1)

    all_nodes = Requirements.compute_all(scope)

    # The rail shows only project-level milestones; the per-story/component
    # fan-out is collapsed into a single placeholder after `qa_setup`.
    all_nodes
    |> Enum.filter(&(&1.entity_type == "project"))
    |> Enum.map(fn node ->
      %{name: node.name, label: requirement_label(node), status: status_for(node, actionable_keys)}
    end)
    |> insert_story_placeholder(project, story_work_status(all_nodes, actionable_keys))
  end

  defp assign_sessions(%{assigns: %{scope: scope}} = socket) do
    sessions =
      scope
      |> Sessions.list_sessions()
      |> Enum.reject(&no_activity?/1)
      |> Enum.reject(&empty?/1)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(@session_cap)

    assign(socket, sessions: sessions)
  end

  # Cheap, in-memory: derive the active session + focused step from the
  # already-loaded sessions and the heartbeat map. No DB, no graph. Help is
  # only re-fetched when the focused task actually changes.
  defp refresh_focus(%{assigns: %{scope: nil}} = socket), do: socket

  defp refresh_focus(socket) do
    %{sessions: sessions, focused_override: override, scope: scope} = socket.assigns

    active_id = active_session_id(sessions)
    focused_task_id = focused_task_id(sessions, active_id, override)

    focused_help =
      case focused_task_id == socket.assigns.focused_task_id do
        true -> socket.assigns.focused_help
        false -> focused_help(scope, sessions, focused_task_id)
      end

    assign(socket,
      active_session_id: active_id,
      focused_task_id: focused_task_id,
      focused_requirement: focused_requirement(sessions, focused_task_id),
      focused_help: focused_help
    )
  end

  # The requirement_name the focused task targets — used to light up the
  # matching rail row.
  defp focused_requirement(_sessions, nil), do: nil

  defp focused_requirement(sessions, task_id) do
    case find_task(sessions, task_id) do
      nil -> nil
      task -> task.requirement_name
    end
  end

  # Active = the most recently updated session, if that update is recent.
  # Sessions arrive sorted newest-first; the PostToolUse hook keeps the
  # working session's updated_at fresh, so recency tracks live work.
  defp active_session_id([%{id: id, updated_at: updated} | _]) do
    case within_window?(updated) do
      true -> id
      false -> nil
    end
  end

  defp active_session_id([]), do: nil

  defp within_window?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at) <= @active_window_seconds

  defp within_window?(_at), do: false

  defp toggle(set, id) do
    case MapSet.member?(set, id) do
      true -> MapSet.delete(set, id)
      false -> MapSet.put(set, id)
    end
  end

  # Manual override wins; otherwise focus the active session's current step.
  defp focused_task_id(_sessions, _active_id, override) when is_binary(override), do: override
  defp focused_task_id(_sessions, nil, _override), do: nil

  defp focused_task_id(sessions, active_id, _override) do
    sessions
    |> Enum.find(&(&1.id == active_id))
    |> current_task()
    |> case do
      nil -> nil
      task -> task.id
    end
  end

  # The agent's current step: the last non-terminal task, chronologically.
  defp current_task(nil), do: nil

  defp current_task(%{tasks: tasks}) do
    tasks
    |> sorted_tasks()
    |> Enum.reject(&terminal?/1)
    |> List.last()
  end

  defp terminal?(%{status: status}), do: status in [:completed, :cancelled]

  defp focused_help(_scope, _sessions, nil), do: nil

  defp focused_help(scope, sessions, task_id) do
    case find_task(sessions, task_id) do
      nil -> nil
      task -> TaskHelp.fetch(scope, task.session_type)
    end
  end

  defp find_task(sessions, task_id) do
    sessions
    |> Enum.flat_map(& &1.tasks)
    |> Enum.find(&(&1.id == task_id))
  end

  # -- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} section={:progress} full_width>

      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error}>
        <div class="grid grid-cols-1 lg:grid-cols-[20rem_1fr_22rem] gap-8">
          <%!-- Left rail: project milestones, status icons, counter + progress --%>
          <aside class="lg:sticky lg:top-4 self-start bg-cms-ink-1 border border-cms-hair-w">
            <div class="p-5 border-b border-cms-hair-w">
              <div class="cms-spec-eyebrow mb-3">// requirements</div>
              <div class="flex items-baseline gap-2">
                <span class="cms-rail-count-num">{req_count(@requirements, "done")}</span>
                <span class="cms-rail-count-meta">
                  / {length(@requirements)} done · {req_count(@requirements, "in progress")} active
                </span>
              </div>
              <div class="cms-rail-bar mt-3">
                <div
                  class="cms-rail-bar-done"
                  style={"width:#{pct(req_count(@requirements, "done"), length(@requirements))}%"}
                >
                </div>
                <div
                  class="cms-rail-bar-active"
                  style={"width:#{pct(req_count(@requirements, "in progress"), length(@requirements))}%"}
                >
                </div>
              </div>
            </div>

            <ul data-test="requirements-list" class="py-2">
              <li
                :if={@requirements_loading and @requirements == []}
                class="cms-rail-item text-cms-text-mute"
              >
                <span class="loading loading-dots loading-xs"></span>
                <span class="cms-rail-item-label">Loading…</span>
              </li>
              <li
                :for={req <- @requirements}
                data-test="requirement-row"
                data-status={req.status}
                class={["cms-rail-item", req.name == @focused_requirement && "is-focus"]}
              >
                <span class="cms-status">
                  <span :if={req.status == "done"} class="cms-status-done">✓</span>
                  <span :if={req.status == "in progress"} class="cms-status-active"></span>
                  <span :if={req.status == "not started"} class="cms-status-todo"></span>
                </span>
                <span class="cms-rail-item-label truncate">{req.label}</span>
                <span :if={req.name == @focused_requirement} class="cms-rail-inview">◂ in view</span>
              </li>
            </ul>
          </aside>

        <%!-- Center: one vertical timeline per session, tasks as dots down the line --%>
        <section>
          <div class="cms-spec-eyebrow mb-5">// sessions · latest 10</div>

          <div data-test="timeline" class="space-y-6">
            <div
              :for={session <- @sessions}
              data-test="session"
              data-session-id={session.id}
              class={["cms-session", session.id != @active_session_id && "is-idle"]}
            >
              <%!-- a session is an untyped Claude conversation; type lives on its tasks --%>
              <div class="flex items-center gap-3 flex-wrap mb-2">
                <span class={["cms-session-marker", session.id == @active_session_id && "is-active"]}></span>
                <span class="cms-session-title">Session</span>
                <span
                  data-test="session-extent"
                  data-started-at={iso(session.inserted_at)}
                  data-updated-at={iso(session.updated_at)}
                  class="cms-session-time"
                >
                  {friendly_time(session.inserted_at)} → {friendly_time(session.updated_at)}
                </span>
                <span :if={session.id == @active_session_id} class="cms-session-live">● live</span>
              </div>

              <%!-- nested task timeline inside the session --%>
              <div class="cms-session-tasks">
                <div class="cms-session-tasks-eyebrow">tasks · {done_count(session)} done</div>

                <%= if collapsed?(session, @expanded_sessions) do %>
                  <.task_row :for={task <- head_tasks(session.tasks)} task={task} focused_task_id={@focused_task_id} />
                  <.tasks_toggle
                    session_id={session.id}
                    label={"… #{hidden_count(session.tasks)} more steps"}
                    test_id="show-more-tasks"
                  />
                  <.task_row :for={task <- tail_tasks(session.tasks)} task={task} focused_task_id={@focused_task_id} />
                <% else %>
                  <.task_row :for={task <- display_tasks(session.tasks)} task={task} focused_task_id={@focused_task_id} />
                  <.tasks_toggle
                    :if={collapsible?(session.tasks)}
                    session_id={session.id}
                    label="Show fewer"
                    test_id="show-fewer-tasks"
                  />
                <% end %>
              </div>
            </div>
          </div>

          <div :if={@sessions == []} class="text-center py-16 text-base-content/50">
            <p class="text-lg font-medium">The agent isn't working on anything right now.</p>
            <p class="text-sm">New activity will appear here automatically.</p>
          </div>
        </section>

        <%!-- Right pane — instrumentation + help (grows to hold per-step help/video) --%>
        <aside class="lg:sticky lg:top-4 self-start lg:max-h-[calc(100vh-7rem)] overflow-y-auto bg-cms-ink-1 border border-cms-hair-w p-5 space-y-4">
          <div class="flex items-center justify-between gap-3">
            <div class="cms-spec-eyebrow">// what's happening</div>
            <span class="cms-spec-readonly inline-flex">read-only</span>
          </div>

          <div class="cms-spec-status" data-live={bool(@active_session_id != nil)}>
            <span class="cms-spec-dot"></span>{if @active_session_id, do: "LIVE", else: "IDLE"}
          </div>

          <div :if={@focused_help} class="cms-spec-eyebrow pt-3 border-t border-cms-hair-w">
            for ▸ {humanize_name(@focused_requirement)}
          </div>
          <.render_help focused_help={@focused_help} />

          <p
            :if={!@focused_help}
            class="text-xs text-cms-text-mute leading-relaxed pt-3 border-t border-cms-hair-w"
          >
            Step-by-step help and a short video will appear here as the agent works.
          </p>
        </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The focused step's help — rendered in the right "what's happening" pane.
  defp render_help(%{focused_help: {:ok, help}} = assigns) do
    assigns = assign(assigns, :help, help)

    ~H"""
    <div class="space-y-3">
      <div data-test="task-help-body" class="cms-help-body prose prose-sm prose-invert max-w-none">
        {CodeMySpecLocalWeb.Markdown.md_html(@help.body)}
      </div>
      <a :if={@help.video_url} data-test="task-help-video" href={@help.video_url} class="cms-help-video">
        <span class="text-2xl leading-none pl-1">▶</span>
        <span class="font-mono text-[10px] uppercase tracking-widest text-cms-text-mute">
          watch
        </span>
      </a>
    </div>
    """
  end

  defp render_help(%{focused_help: :generic} = assigns) do
    ~H"""
    <div data-test="task-help-generic" class="cms-help-generic">
      The agent is working on this step.
    </div>
    """
  end

  defp render_help(assigns), do: ~H""

  # One task on the session's nested timeline. The focused step expands into
  # the artifact card; every other step is a node (done ✓ / cancelled ✕ /
  # queued ○). Help lives in the right pane, not here.
  defp task_row(assigns) do
    assigns = assign(assigns, :expanded, expanded?(assigns.task, assigns.focused_task_id))

    ~H"""
    <div
      :if={@expanded}
      data-test="task"
      data-task-id={@task.id}
      data-expanded="true"
      style={agent_style(@task.session_type)}
      class="cms-task-row items-start"
    >
      <span class="cms-task-glyph pt-1"><span class="cms-task-dot-active"></span></span>
      <button
        type="button"
        data-test="task-toggle"
        phx-click="focus_task"
        phx-value-id={@task.id}
        class="flex-1 min-w-0 text-left"
      >
        <div class="cms-artifact">
          <div class="cms-artifact-bar"></div>
          <div class="cms-artifact-head">
            <div class="flex items-center gap-3 min-w-0">
              <span class="cms-artifact-title truncate">{humanize_name(@task.requirement_name)}</span>
              <span data-test="task-type" class="cms-agent-tag">{agent_label(@task.session_type)}</span>
            </div>
            <span class="cms-artifact-active">● active</span>
          </div>
          <div class="cms-artifact-body">
            <div data-test="task-artifact">
              <div class="cms-artifact-eyebrow">// artifact</div>
              <div class="cms-artifact-mono">{artifact_summary(@task)}</div>
            </div>
          </div>
        </div>
      </button>
    </div>
    <div
      :if={!@expanded}
      data-test="task"
      data-task-id={@task.id}
      data-expanded="false"
      style={agent_style(@task.session_type)}
      class="cms-task-row"
    >
      <span class="cms-task-glyph">
        <span :if={@task.status == :completed} class="cms-task-dot-done">✓</span>
        <span :if={@task.status == :cancelled} class="cms-task-dot-done text-cms-text-mute">✕</span>
        <span :if={@task.status not in [:completed, :cancelled]} class="cms-task-dot-todo"></span>
      </span>
      <button
        type="button"
        data-test="task-toggle"
        phx-click="focus_task"
        phx-value-id={@task.id}
        class={[
          "cms-task-label flex-1 truncate text-left hover:text-cms-text",
          @task.status not in [:completed, :cancelled] && "is-todo"
        ]}
      >
        {humanize_name(@task.requirement_name)}
      </button>
      <span data-test="task-type" class="cms-agent-tag shrink-0">{agent_label(@task.session_type)}</span>
    </div>
    """
  end

  # The "… N more steps" / "Show fewer" toggle for a collapsed task middle.
  defp tasks_toggle(assigns) do
    ~H"""
    <div class="cms-task-row">
      <span class="cms-task-glyph"><span class="cms-task-dot-todo"></span></span>
      <button
        type="button"
        data-test={@test_id}
        phx-click="toggle_session_tasks"
        phx-value-id={@session_id}
        class="cms-task-label text-left hover:text-cms-text"
      >
        {@label}
      </button>
    </div>
    """
  end

  # -- Helpers -------------------------------------------------------------

  defp requirement_key(%{entity_type: t, entity_id: id, name: name}), do: {t, id, name}

  defp status_for(%{satisfied: true}, _actionable), do: "done"

  defp status_for(node, actionable) do
    case MapSet.member?(actionable, requirement_key(node)) do
      true -> "in progress"
      false -> "not started"
    end
  end

  defp requirement_label(%{entity_name: name, name: req}) when name in [nil, ""], do: req
  defp requirement_label(%{entity_name: name, name: req}), do: "#{name} — #{req}"

  # A single rail row standing in for all per-story / per-component work,
  # inserted where the graph fans out (right after `qa_setup`).
  defp insert_story_placeholder(rows, project, status) do
    placeholder = %{name: "__story_work__", label: "#{project_name(project)} — story work", status: status}

    case Enum.find_index(rows, &(&1.name == "qa_setup")) do
      nil -> rows ++ [placeholder]
      idx -> List.insert_at(rows, idx + 1, placeholder)
    end
  end

  defp project_name(%{name: name}) when is_binary(name), do: name
  defp project_name(_), do: "Project"

  defp story_work_status(all_nodes, actionable) do
    all_nodes
    |> Enum.filter(&(&1.entity_type in ["story", "component"]))
    |> classify_story_work(actionable)
  end

  defp classify_story_work([], _actionable), do: "not started"

  defp classify_story_work(nodes, actionable) do
    all_done? = Enum.all?(nodes, & &1.satisfied)
    any_active? = Enum.any?(nodes, &MapSet.member?(actionable, requirement_key(&1)))
    story_status(all_done?, any_active?)
  end

  defp story_status(true, _any_active?), do: "done"
  defp story_status(false, true), do: "in progress"
  defp story_status(false, false), do: "not started"

  defp no_activity?(%{inserted_at: started, updated_at: updated}),
    do: DateTime.compare(started, updated) == :eq

  defp empty?(%{tasks: tasks}), do: tasks in [nil, []]

  defp expanded?(%{id: id}, focused_id), do: id == focused_id

  defp artifact_summary(%{expected_files: [_ | _] = files}), do: Enum.join(files, ", ")
  defp artifact_summary(%{requirement_name: name}), do: name

  defp bool(true), do: "true"
  defp bool(_), do: "false"

  defp iso(nil), do: ""
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # -- Display helpers -----------------------------------------------------

  defp humanize_name(name) when is_binary(name) and name != "",
    do: name |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  defp humanize_name(_), do: "Task"

  defp friendly_time(nil), do: "—"
  defp friendly_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")

  # Chronological order (oldest → newest); `current_task` reads the tail.
  defp sorted_tasks(tasks) when is_list(tasks),
    do: Enum.sort_by(tasks, &(task_time(&1) || ~U[1970-01-01 00:00:00Z]), DateTime)

  defp sorted_tasks(_tasks), do: []

  # Newest-first for display, matching the newest-session-on-top ordering.
  defp display_tasks(tasks), do: tasks |> sorted_tasks() |> Enum.reverse()

  # Collapse a session's task middle once it grows past the threshold,
  # unless the user has explicitly expanded that session.
  defp collapsed?(session, expanded_sessions),
    do: collapsible?(session.tasks) and not MapSet.member?(expanded_sessions, session.id)

  defp collapsible?(tasks) when is_list(tasks), do: length(tasks) > @task_collapse_threshold
  defp collapsible?(_tasks), do: false

  defp head_tasks(tasks), do: tasks |> display_tasks() |> Enum.take(@task_head)
  defp tail_tasks(tasks), do: tasks |> display_tasks() |> Enum.take(-@task_tail)
  defp hidden_count(tasks), do: length(tasks) - @task_head - @task_tail

  defp task_time(%{started_at: %DateTime{} = started}), do: started
  defp task_time(%{completed_at: %DateTime{} = completed}), do: completed
  defp task_time(_task), do: nil

  defp done_count(%{tasks: tasks}) when is_list(tasks),
    do: Enum.count(tasks, &(&1.status == :completed))

  defp done_count(_session), do: 0

  # ── Agent mapping — task type → palette key + tag. Match only the last
  # module segment (the type name); the app namespace `CodeMySpec` itself
  # contains both "Spec" and "Code", so matching the full path misclassifies. ──
  defp agent_key(type) do
    name = type |> to_string() |> String.split(".") |> List.last() || ""

    cond do
      String.contains?(name, "Architecture") -> :arch
      String.contains?(name, "Qa") -> :qa
      String.contains?(name, "Bdd") -> :bdd
      String.contains?(name, "Spec") -> :spec
      String.contains?(name, ["Code", "Develop", "Generation", "Implementation"]) -> :code
      String.contains?(name, ["ThreeAmigos", "Story", "Persona", "Interview"]) -> :pm
      true -> :qa
    end
  end

  defp agent_style(type), do: "--ac: var(--color-cms-agent-#{agent_key(type)});"

  defp agent_label(type), do: Atom.to_string(agent_key(type))

  defp req_count(requirements, status), do: Enum.count(requirements, &(&1.status == status))

  defp pct(_n, 0), do: 0
  defp pct(n, total), do: round(n / total * 100)
end
