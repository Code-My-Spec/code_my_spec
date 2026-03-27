defmodule CodeMySpecLocalWeb.NextTaskController do
  @moduledoc """
  Browser preview for the next actionable task.

  Shows what the next requirement would be without drafting a task.
  Agents use the DraftTask MCP tool instead.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpecLocalWeb.NextTaskMarkdown

  def show(conn, _params) do
    scope = conn.assigns.current_scope
    project = scope.active_project

    result = ProjectCoordinator.get_next_actions(scope)
    markdown = NextTaskMarkdown.render(result, scope, project)
    text(conn, markdown)
  end
end
