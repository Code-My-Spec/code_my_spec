defmodule CodeMySpecLocalWeb.SessionsLive do
  @moduledoc """
  Human interface for project sessions.

  Renders the same markdown as the LLM API via SessionsMarkdown.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Sessions.Session
  alias CodeMySpecLocalWeb.SessionsMarkdown
  alias CodeMySpecLocalWeb.TaskMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name, "id" => id, "task_id" => task_id}, _uri, %{assigns: %{live_action: :task_show}} = socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      case Sessions.get_session(scope, id) do
        nil ->
          {:noreply, assign(socket, error: "Session not found: #{id}")}

        session ->
          case Session.find_task(session, task_id) do
            nil ->
              {:noreply, assign(socket, error: "Task not found: #{task_id}")}

            task ->
              markdown = TaskMarkdown.show(task, session, project)
              {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
          end
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  def handle_params(%{"project_name" => name, "id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      case Sessions.get_session(scope, id) do
        nil ->
          {:noreply, assign(socket, error: "Session not found: #{id}")}

        session ->
          markdown = SessionsMarkdown.show(session, project)
          {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      sessions = Sessions.list_sessions(scope)
      markdown = SessionsMarkdown.index(sessions, project)

      {:noreply, assign(socket, project: project, markdown: markdown, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} class="text-red-400">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@markdown} class="prose prose-invert max-w-none">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end
end
