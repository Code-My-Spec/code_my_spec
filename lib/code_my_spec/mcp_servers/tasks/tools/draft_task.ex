defmodule CodeMySpec.McpServers.Tasks.Tools.DraftTask do
  @moduledoc """
  Find the next actionable requirement and prepare a draft task on your session.

  This is your starting point for each work cycle. It queries the requirement
  graph for the next unsatisfied requirement with all prerequisites met, creates
  a prepared task on your session, and returns the requirement details along with
  the session_id and task_id you need to start it.

  After receiving the draft, call `start_task` or pass the call information to a subagent
  to start the task and assign it to the calling agent.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string,
      required: true,
      doc: "Your Claude session/conversation ID"
  end

  @impl true
  def execute(%{session_id: session_id}, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id) do
      result = ProjectCoordinator.get_next_actions(scope)
      handle_result(scope, session, result, frame)
    else
      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  defp resolve_session(scope, session_id) do
    session = safe_get_session(scope, session_id)

    case session do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp safe_get_session(scope, session_id) do
    Sessions.get_session(scope, session_id) ||
      Sessions.get_by_external_id(scope, session_id)
  rescue
    Ecto.Query.CastError -> Sessions.get_by_external_id(scope, session_id)
  end

  defp handle_result(_scope, _session, :complete, frame) do
    {:reply, TasksMapper.all_complete_response(), frame}
  end

  defp handle_result(_scope, _session, {:error, reason}, frame) do
    {:reply, TasksMapper.error(reason), frame}
  end

  defp handle_result(scope, session, {:ok, requirement}, frame) do
    requirement = Repo.preload(requirement, [:component, :story])

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
          |> Enum.filter(
            &(&1.requirement_name == requirement.name and &1.status in [:prepared, :active])
          )
          |> List.last()

        if task do
          {:reply, TasksMapper.draft_task_response(requirement, session.id, task.id), frame}
        else
          {:reply, TasksMapper.error("Failed to locate prepared task"), frame}
        end

      {:error, reason} ->
        Logger.warning("[DraftTask] Failed to prepare task: #{inspect(reason)}")
        {:reply, TasksMapper.error("Failed to prepare task: #{inspect(reason)}"), frame}
    end
  end
end
