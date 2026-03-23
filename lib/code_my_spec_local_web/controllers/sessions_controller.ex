defmodule CodeMySpecLocalWeb.SessionsController do
  @moduledoc """
  LLM API for project sessions.

  Returns sessions as plain text markdown.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpecLocalWeb.SessionsMarkdown
  alias CodeMySpecLocalWeb.TaskMarkdown

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    sessions = Sessions.list_sessions(scope)
    markdown = SessionsMarkdown.index(sessions, scope.active_project)
    text(conn, markdown)
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Sessions.get_session(scope, id) do
      nil ->
        conn |> put_status(404) |> text("Session not found: #{id}")

      session ->
        markdown = SessionsMarkdown.show(session, scope.active_project)
        text(conn, markdown)
    end
  end

  def show_task(conn, %{"session_id" => session_id, "task_id" => task_id}) do
    scope = conn.assigns.current_scope

    with %Session{} = session <- Sessions.get_session(scope, session_id),
         %{} = task <- Session.find_task(session, task_id) do
      markdown = TaskMarkdown.show(task, session, scope.active_project)
      text(conn, markdown)
    else
      nil -> conn |> put_status(404) |> text("Not found")
    end
  end
end
