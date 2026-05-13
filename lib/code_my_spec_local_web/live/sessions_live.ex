defmodule CodeMySpecLocalWeb.SessionsLive do
  @moduledoc """
  Human interface for project sessions.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Configurations
  alias CodeMySpec.Projects
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       sessions: [],
       session: nil,
       task: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, %{"project_name" => name}) do
    case load_project(name) do
      {:ok, project, scope} ->
        sessions = Sessions.list_sessions(scope)

        assign(socket,
          project: project,
          sessions: sessions,
          session: nil,
          task: nil,
          page_title: "#{project.name} — Sessions",
          error: nil
        )

      {:error, reason} ->
        assign(socket, error: "Failed to load project: #{inspect(reason)}")
    end
  end

  defp apply_action(socket, :show, %{"project_name" => name, "id" => id}) do
    case load_project(name) do
      {:ok, project, scope} -> assign_session(socket, project, scope, id)
      {:error, reason} -> assign(socket, error: "Failed to load project: #{inspect(reason)}")
    end
  end

  defp apply_action(socket, :task_show, %{"project_name" => name, "id" => id, "task_id" => task_id}) do
    case load_project(name) do
      {:ok, project, scope} -> assign_task(socket, project, scope, id, task_id)
      {:error, reason} -> assign(socket, error: "Failed to load project: #{inspect(reason)}")
    end
  end

  defp assign_session(socket, project, scope, id) do
    case Sessions.get_session(scope, id) do
      nil ->
        assign(socket, project: project, error: "Session not found: #{id}")

      session ->
        ttl = Configurations.get_or_create(scope).subagent_ttl_minutes
        active_subagents = Session.active_subagents(session, ttl)

        assign(socket,
          project: project,
          session: session,
          active_subagents: active_subagents,
          task: nil,
          page_title: "#{project.name} — Session",
          error: nil
        )
    end
  end

  defp assign_task(socket, project, scope, id, task_id) do
    case Sessions.get_session(scope, id) do
      nil ->
        assign(socket, project: project, error: "Session not found: #{id}")

      session ->
        case Session.find_task(session, task_id) do
          nil ->
            assign(socket, project: project, error: "Task not found: #{task_id}")

          task ->
            assign(socket,
              project: project,
              session: session,
              task: task,
              page_title: "#{project.name} — Task",
              error: nil
            )
        end
    end
  end

  defp load_project(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:sessions}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@live_action == :index && !@error}>
        {render_index(assigns)}
      </div>

      <div :if={@live_action == :show && @session && !@error}>
        {render_show(assigns)}
      </div>

      <div :if={@live_action == :task_show && @task && !@error}>
        {render_task(assigns)}
      </div>
    </Layouts.app>
    """
  end

  defp render_index(assigns) do
    active = Enum.count(assigns.sessions, &(&1.status == :active))
    total = length(assigns.sessions)
    assigns = assign(assigns, active: active, total: total)

    ~H"""
    <div class="mb-6">
      <h1 class="text-3xl font-bold">
        Sessions
        <span class="text-base-content/50 font-normal text-xl">
          ({@active} active / {@total} total)
        </span>
      </h1>
    </div>

    <div :if={@sessions == []} class="text-base-content/50 py-12 text-center border border-dashed border-base-300 rounded-box">
      No sessions found.
    </div>

    <div :if={@sessions != []} class="overflow-x-auto rounded-box border border-base-300">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Status</th>
            <th>Type</th>
            <th class="hidden md:table-cell">Tasks</th>
            <th class="hidden sm:table-cell">Started</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={session <- @sessions}
            class="hover cursor-pointer"
            phx-click={JS.navigate(~p"/projects/#{slug(@project)}/sessions/#{session.id}")}
          >
            <td><span class={"badge badge-sm #{status_class(session.status)}"}>{session.status}</span></td>
            <td class="font-medium">{format_type(session.type)}</td>
            <td class="hidden md:table-cell text-sm opacity-70">
              {task_summary(session)}
            </td>
            <td class="hidden sm:table-cell text-sm opacity-50">
              <span :if={session.inserted_at}>{Calendar.strftime(session.inserted_at, "%b %d, %H:%M")}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <div class="mb-4">
      <.link navigate={~p"/projects/#{slug(@project)}/sessions"} class="btn btn-ghost btn-sm gap-1">
        ← Sessions
      </.link>
    </div>

    <div class="flex items-start justify-between gap-4 mb-6">
      <h1 class="text-2xl font-bold">Session: {format_type(@session.type)}</h1>
      <span class={"badge #{status_class(@session.status)}"}>{@session.status}</span>
    </div>

    <div class="card bg-base-200 border border-base-300 mb-6">
      <div class="card-body text-sm">
        <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1">
          <dt :if={@session.external_conversation_id} class="font-semibold opacity-70">External ID</dt>
          <dd :if={@session.external_conversation_id} class="font-mono">{@session.external_conversation_id}</dd>

          <dt :if={@session.component_module_name} class="font-semibold opacity-70">Component</dt>
          <dd :if={@session.component_module_name}>{@session.component_module_name}</dd>

          <dt :if={@session.inserted_at} class="font-semibold opacity-70">Started</dt>
          <dd :if={@session.inserted_at}>{Calendar.strftime(@session.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}</dd>

          <dt :if={@session.updated_at} class="font-semibold opacity-70">Updated</dt>
          <dd :if={@session.updated_at}>{Calendar.strftime(@session.updated_at, "%Y-%m-%d %H:%M:%S UTC")}</dd>
        </dl>
      </div>
    </div>

    <h2 class="text-lg font-semibold mb-3" data-test="registered-subagents-heading">
      Registered Sub-agents <span class="text-base-content/50 font-normal">({length(@active_subagents)})</span>
    </h2>

    <p :if={@active_subagents == []} class="text-base-content/50 mb-6">No registered sub-agents.</p>

    <div :if={@active_subagents != []} class="overflow-x-auto rounded-box border border-base-300 mb-6">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Name</th>
            <th class="hidden md:table-cell">Agent ID</th>
            <th class="hidden sm:table-cell">Registered</th>
            <th>Assignment</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={sa <- @active_subagents} data-test="subagent-row" data-agent-id={sa.agent_id}>
            <td class="font-medium">{sa.agent_name || "—"}</td>
            <td class="hidden md:table-cell text-xs font-mono opacity-70">{sa.agent_id}</td>
            <td class="hidden sm:table-cell text-xs opacity-50">
              <span :if={sa.last_heartbeat_at}>{Calendar.strftime(sa.last_heartbeat_at, "%H:%M:%S")}</span>
            </td>
            <td class="text-sm">
              {subagent_assignment(@session, sa.agent_id)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <h2 class="text-lg font-semibold mb-3">
      Tasks <span class="text-base-content/50 font-normal">({task_completed_count(@session)}/{task_count(@session)})</span>
    </h2>

    <p :if={(@session.tasks || []) == []} class="text-base-content/50">No tasks recorded.</p>

    <div :if={(@session.tasks || []) != []} class="overflow-x-auto rounded-box border border-base-300">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Status</th>
            <th>Type</th>
            <th class="hidden md:table-cell">Component</th>
            <th class="hidden lg:table-cell">Requirement</th>
            <th class="hidden sm:table-cell">Time</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={task <- @session.tasks || []}
            class="hover cursor-pointer"
            phx-click={JS.navigate(~p"/projects/#{slug(@project)}/sessions/#{@session.id}/tasks/#{task.id}")}
          >
            <td><span class={"badge badge-sm #{status_class(task.status)}"}>{task.status}</span></td>
            <td class="font-medium">{format_type(task.session_type)}</td>
            <td class="hidden md:table-cell text-sm opacity-70">{task.component_module_name || "—"}</td>
            <td class="hidden lg:table-cell text-sm opacity-70">{task.requirement_name || "—"}</td>
            <td class="hidden sm:table-cell text-xs opacity-50">
              <span :if={task.completed_at}>done {Calendar.strftime(task.completed_at, "%H:%M:%S")}</span>
              <span :if={!task.completed_at && task.started_at}>started {Calendar.strftime(task.started_at, "%H:%M:%S")}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div :if={@session.state && @session.state != %{}} class="mt-6">
      <h2 class="text-lg font-semibold mb-2">State</h2>
      <pre class="bg-base-200 border border-base-300 rounded-box p-4 text-xs overflow-x-auto"><code>{Jason.encode!(@session.state, pretty: true)}</code></pre>
    </div>
    """
  end

  defp render_task(assigns) do
    ~H"""
    <div class="mb-4">
      <.link navigate={~p"/projects/#{slug(@project)}/sessions/#{@session.id}"} class="btn btn-ghost btn-sm gap-1">
        ← Session
      </.link>
    </div>

    <div class="flex items-start justify-between gap-4 mb-6">
      <h1 class="text-2xl font-bold">Task: {format_type(@task.session_type)}</h1>
      <span class={"badge #{status_class(@task.status)}"}>{@task.status}</span>
    </div>

    <div class="card bg-base-200 border border-base-300 mb-6">
      <div class="card-body p-0">
        <table class="table table-sm">
          <tbody>
            <tr><td class="font-semibold opacity-70 w-40">Requirement</td><td>{@task.requirement_name || "—"}</td></tr>
            <tr><td class="font-semibold opacity-70">Component</td><td>{@task.component_module_name || "—"}</td></tr>
            <tr><td class="font-semibold opacity-70">Story ID</td><td>{@task.story_id || "—"}</td></tr>
            <tr><td class="font-semibold opacity-70">Agent ID</td><td class="font-mono">{@task.agent_id || "not assigned"}</td></tr>
            <tr><td class="font-semibold opacity-70">Started</td><td>{if @task.started_at, do: Calendar.strftime(@task.started_at, "%Y-%m-%d %H:%M:%S UTC"), else: "—"}</td></tr>
            <tr><td class="font-semibold opacity-70">Completed</td><td>{if @task.completed_at, do: Calendar.strftime(@task.completed_at, "%Y-%m-%d %H:%M:%S UTC"), else: "—"}</td></tr>
          </tbody>
        </table>
      </div>
    </div>

    <div :if={has_expected_files?(@task)}>
      <h2 class="text-lg font-semibold mb-2">Expected Files</h2>
      <ul class="menu menu-sm bg-base-200 border border-base-300 rounded-box">
        <li :for={file <- @task.expected_files}><a><code class="text-sm">{file}</code></a></li>
      </ul>
    </div>
    """
  end

  defp status_class(:active), do: "badge-info"
  defp status_class(:completed), do: "badge-success"
  defp status_class(:complete), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:cancelled), do: "badge-neutral"
  defp status_class(:prepared), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"

  defp format_type(nil), do: "Unknown"
  defp format_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.split(".") |> List.last()
  defp format_type(type) when is_binary(type), do: type

  defp task_summary(%{tasks: tasks}) when is_list(tasks) and tasks != [] do
    active = Enum.count(tasks, &(&1.status == :active))
    completed = Enum.count(tasks, &(&1.status in [:completed, :failed, :cancelled]))
    total = length(tasks)
    "#{completed}/#{total}" <> if(active > 0, do: " (#{active} active)", else: "")
  end

  defp task_summary(_), do: "—"

  defp task_count(%{tasks: tasks}) when is_list(tasks), do: length(tasks)
  defp task_count(_), do: 0

  defp task_completed_count(%{tasks: tasks}) when is_list(tasks) do
    Enum.count(tasks, &(&1.status in [:completed, :failed, :cancelled]))
  end

  defp task_completed_count(_), do: 0

  defp has_expected_files?(%{expected_files: files}) when is_list(files) and files != [], do: true
  defp has_expected_files?(_), do: false

  defp subagent_assignment(session, agent_id) do
    case Session.find_task_by_agent(session, agent_id) do
      nil -> "idle"
      task -> "assigned: #{task.requirement_name || task.id}"
    end
  end

  defp slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
