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

  def show(conn, _params) do
    scope = conn.assigns.current_scope
    project = scope.active_project

    result = ProjectCoordinator.get_next_actions(scope)

    # If there's an actionable requirement and an active session, prepare a draft task
    task_info =
      case result do
        {:ok, requirement} ->
          prepare_draft_task(scope, requirement)

        _ ->
          nil
      end

    markdown = NextTaskMarkdown.render(result, scope, project, task_info)

    text(conn, markdown)
  end

  defp prepare_draft_task(scope, requirement) do
    requirement = Repo.preload(requirement, [:component])

    case Sessions.list_active_sessions(scope) do
      [session | _] ->
        task_attrs = %{
          session_type: requirement.satisfied_by,
          requirement_name: requirement.name,
          project_id: scope.active_project_id,
          component_id: requirement.component_id,
          component_module_name:
            case requirement.component do
              %{module_name: name} -> name
              _ -> nil
            end,
          story_id: requirement.story_id
        }

        case Sessions.prepare_task(scope, session, task_attrs) do
          {:ok, updated_session} ->
            task =
              updated_session.tasks
              |> Enum.filter(&(&1.status == :prepared))
              |> List.last()

            {session.id, task.id}

          {:error, reason} ->
            Logger.warning("[NextTask] Failed to prepare task: #{inspect(reason)}")
            nil
        end

      [] ->
        Logger.info("[NextTask] No active session — skipping task preparation")
        nil
    end
  end
end
