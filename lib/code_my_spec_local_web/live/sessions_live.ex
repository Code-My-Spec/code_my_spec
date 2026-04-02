defmodule CodeMySpecLocalWeb.SessionsLive do
  @moduledoc """
  Human interface for project sessions.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, sessions: [], session: nil, task: nil, error: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, %{"project_name" => name}) do
    with {:ok, project, scope} <- load_project(name) do
      sessions = Sessions.list_sessions(scope)
      assign(socket, project: project, sessions: sessions, session: nil, task: nil, error: nil)
    else
      {:error, reason} -> assign(socket, error: "Failed to load project: #{inspect(reason)}")
    end
  end

  defp apply_action(socket, :show, %{"project_name" => name, "id" => id}) do
    with {:ok, project, scope} <- load_project(name) do
      case Sessions.get_session(scope, id) do
        nil -> assign(socket, error: "Session not found: #{id}")
        session -> assign(socket, project: project, session: session, task: nil, error: nil)
      end
    else
      {:error, reason} -> assign(socket, error: "Failed to load project: #{inspect(reason)}")
    end
  end

  defp apply_action(socket, :task_show, %{"project_name" => name, "id" => id, "task_id" => task_id}) do
    with {:ok, project, scope} <- load_project(name) do
      case Sessions.get_session(scope, id) do
        nil ->
          assign(socket, error: "Session not found: #{id}")

        session ->
          case Session.find_task(session, task_id) do
            nil -> assign(socket, error: "Task not found: #{task_id}")
            task -> assign(socket, project: project, session: session, task: task, error: nil)
          end
      end
    else
      {:error, reason} -> assign(socket, error: "Failed to load project: #{inspect(reason)}")
    end
  end

  defp load_project(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="alert alert-error">
      <p>{@error}</p>
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
    """
  end

  defp render_index(assigns) do
    active = Enum.count(assigns.sessions, &(&1.status == :active))
    total = length(assigns.sessions)
    assigns = assign(assigns, active: active, total: total)

    ~H"""
    <div class="prose prose-invert max-w-none">
      <h1>Sessions ({@active} active / {@total} total)</h1>

      <p :if={@sessions == []}>No sessions found.</p>

      <ul :if={@sessions != []}>
        <li :for={session <- @sessions}>
          {status_badge(session.status)}
          <.link navigate={~p"/projects/#{slug(@project)}/sessions/#{session.id}"} class="link link-primary">
            {format_type(session.type)}
          </.link>
          <span :if={session.external_conversation_id} class="font-mono text-xs opacity-60">
            {truncate(session.external_conversation_id, 12)}
          </span>
          <span :if={session.tasks != []} class="text-xs opacity-60">
            ({task_summary(session)})
          </span>
          <span :if={session.inserted_at} class="text-xs opacity-40">
            — {Calendar.strftime(session.inserted_at, "%Y-%m-%d %H:%M")}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <div class="prose prose-invert max-w-none">
      <p>
        <.link navigate={~p"/projects/#{slug(@project)}/sessions"} class="link">
          &larr; Back to sessions
        </.link>
      </p>

      <h1>Session: {format_type(@session.type)}</h1>

      <p><strong>Status:</strong> {status_badge(@session.status)} {@session.status}</p>

      <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
        <dt :if={@session.external_conversation_id} class="font-semibold">External ID</dt>
        <dd :if={@session.external_conversation_id} class="font-mono">{@session.external_conversation_id}</dd>

        <dt :if={@session.component_module_name} class="font-semibold">Component</dt>
        <dd :if={@session.component_module_name}>{@session.component_module_name}</dd>

        <dt :if={@session.inserted_at} class="font-semibold">Started</dt>
        <dd :if={@session.inserted_at}>{Calendar.strftime(@session.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}</dd>

        <dt :if={@session.updated_at} class="font-semibold">Updated</dt>
        <dd :if={@session.updated_at}>{Calendar.strftime(@session.updated_at, "%Y-%m-%d %H:%M:%S UTC")}</dd>
      </dl>

      <h2>Tasks ({task_completed_count(@session)}/{task_count(@session)})</h2>

      <p :if={(@session.tasks || []) == []}>No tasks recorded.</p>

      <ul :if={(@session.tasks || []) != []}>
        <li :for={task <- @session.tasks || []}>
          {status_badge(task.status)}
          <.link
            navigate={~p"/projects/#{slug(@project)}/sessions/#{@session.id}/tasks/#{task.id}"}
            class="link link-primary font-semibold"
          >
            {format_type(task.session_type)}
          </.link>
          <span :if={task.component_module_name} class="text-sm opacity-60">
            — {task.component_module_name}
          </span>
          <span :if={task.requirement_name} class="text-sm opacity-60">
            ({task.requirement_name})
          </span>
          <span :if={task.completed_at} class="text-xs opacity-40">
            — completed {Calendar.strftime(task.completed_at, "%H:%M:%S")}
          </span>
          <span :if={!task.completed_at && task.started_at} class="text-xs opacity-40">
            — started {Calendar.strftime(task.started_at, "%H:%M:%S")}
          </span>
        </li>
      </ul>

      <div :if={@session.state && @session.state != %{}}>
        <h2>State</h2>
        <pre class="text-xs"><code>{Jason.encode!(@session.state, pretty: true)}</code></pre>
      </div>
    </div>
    """
  end

  defp render_task(assigns) do
    ~H"""
    <div class="prose prose-invert max-w-none">
      <p>
        <.link navigate={~p"/projects/#{slug(@project)}/sessions/#{@session.id}"} class="link">
          &larr; Back to session
        </.link>
      </p>

      <h1>Task: {format_type(@task.session_type)}</h1>

      <p><strong>Status:</strong> {status_badge(@task.status)} {@task.status}</p>

      <table class="text-sm">
        <tbody>
          <tr><td class="font-semibold pr-6 py-1 align-top">Requirement</td><td class="py-1">{@task.requirement_name || "—"}</td></tr>
          <tr><td class="font-semibold pr-6 py-1 align-top">Component</td><td class="py-1">{@task.component_module_name || "—"}</td></tr>
          <tr><td class="font-semibold pr-6 py-1 align-top">Story ID</td><td class="py-1">{@task.story_id || "—"}</td></tr>
          <tr><td class="font-semibold pr-6 py-1 align-top">Agent ID</td><td class="py-1 font-mono">{@task.agent_id || "not assigned"}</td></tr>
          <tr><td class="font-semibold pr-6 py-1 align-top">Started</td><td class="py-1">{if @task.started_at, do: Calendar.strftime(@task.started_at, "%Y-%m-%d %H:%M:%S UTC"), else: "—"}</td></tr>
          <tr><td class="font-semibold pr-6 py-1 align-top">Completed</td><td class="py-1">{if @task.completed_at, do: Calendar.strftime(@task.completed_at, "%Y-%m-%d %H:%M:%S UTC"), else: "—"}</td></tr>
        </tbody>
      </table>

      <div :if={has_expected_files?(@task)}>
        <h2>Expected Files</h2>
        <ul>
          <li :for={file <- @task.expected_files}>
            <code>{file}</code>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp status_badge(:active), do: "🔵"
  defp status_badge(:completed), do: "✅"
  defp status_badge(:complete), do: "✅"
  defp status_badge(:failed), do: "❌"
  defp status_badge(:cancelled), do: "⚪"
  defp status_badge(:prepared), do: "⏳"
  defp status_badge(_), do: "○"

  defp format_type(nil), do: "Unknown"
  defp format_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.split(".") |> List.last()
  defp format_type(type) when is_binary(type), do: type

  defp task_summary(%{tasks: tasks}) when is_list(tasks) and tasks != [] do
    active = Enum.count(tasks, &(&1.status == :active))
    completed = Enum.count(tasks, &(&1.status in [:completed, :failed, :cancelled]))
    total = length(tasks)
    "#{completed}/#{total} tasks" <> if(active > 0, do: ", #{active} active", else: "")
  end

  defp task_summary(_), do: ""

  defp task_count(%{tasks: tasks}) when is_list(tasks), do: length(tasks)
  defp task_count(_), do: 0

  defp task_completed_count(%{tasks: tasks}) when is_list(tasks) do
    Enum.count(tasks, &(&1.status in [:completed, :failed, :cancelled]))
  end

  defp task_completed_count(_), do: 0

  defp has_expected_files?(%{expected_files: files}) when is_list(files) and files != [], do: true
  defp has_expected_files?(_), do: false

  defp truncate(str, len) when byte_size(str) > len, do: String.slice(str, 0, len) <> "…"
  defp truncate(str, _len), do: str

  defp slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
