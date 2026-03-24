defmodule CodeMySpecLocalWeb.NextTaskController do
  @moduledoc """
  LLM API for the next actionable task.

  Finds the next requirement, creates a draft task on the session,
  and returns markdown with a link to start-task (which gates the prompt).
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpecLocalWeb.NextTaskMarkdown

  def show(conn, %{"session_id" => session_id} = _params) when is_binary(session_id) do
    scope = conn.assigns.current_scope
    project = scope.active_project

    # session_id from the hook is Claude's external conversation ID
    session = Sessions.get_session(scope, session_id) || Sessions.get_by_external_id(scope, session_id)

    case session do
      nil ->
        conn |> put_status(404) |> text("Session not found: #{session_id}")

      session ->
        result = ProjectCoordinator.get_next_actions(scope)
        task_info = prepare_draft_task(scope, session, result)
        markdown = NextTaskMarkdown.render(result, scope, project, task_info)
        text(conn, markdown)
    end
  end

  def show(conn, _params) do
    conn |> put_status(400) |> text("session_id query parameter is required")
  end

  defp prepare_draft_task(_scope, _session, {:error, _}), do: nil
  defp prepare_draft_task(_scope, _session, :complete), do: nil

  defp prepare_draft_task(scope, session, {:ok, requirement}) do
    requirement = Repo.preload(requirement, [:component])

    task_attrs = %{
      session_type: requirement.satisfied_by,
      requirement_id: requirement.id,
      requirement_name: requirement.name,
      project_id: scope.active_project_id,
      component_id: requirement.component_id,
      component_module_name:
        case requirement.component do
          %{module_name: name} -> name
          _ -> nil
        end,
      story_id: requirement.story_id,
      execution_type: requirement.execution_type || :main_agent,
      validation_type: requirement.validation_type || :automatic
    }

    case Sessions.prepare_task(scope, session, task_attrs) do
      {:ok, updated_session} ->
        task =
          updated_session.tasks
          |> Enum.filter(&(&1.requirement_name == requirement.name and &1.status in [:prepared, :active]))
          |> List.last()

        if task, do: {session.id, task.id}, else: nil

      {:error, reason} ->
        Logger.warning("[NextTask] Failed to prepare task: #{inspect(reason)}")
        nil
    end
  end
end
