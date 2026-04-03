defmodule CodeMySpecLocalWeb.Hooks.StopController do
  @moduledoc """
  Handles the Stop hook event.

  Validates the session transcript and checks if there's more work to do.
  Blocks the stop if actionable tasks remain, directing the agent to get_next_requirement.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation.TaskEvaluator

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    # Step 1: Sync files and components
    if scope.cwd do
      {:ok, file_result} = FileSync.sync(scope, base_dir: scope.cwd)

      FileComponentSync.sync_from_files(scope,
        base_dir: scope.cwd,
        changed_paths: file_result.changed_paths
      )
    end

    # Step 2: Resolve session + active task
    session = session_id && Sessions.get_by_external_id(scope, session_id)
    active_task = session && Session.active_task(session)

    # Step 3: Log files changed during the active task
    if active_task && active_task.started_at do
      changed = Files.changed_since(scope, active_task.started_at)

      if changed != [] do
        by_role = Enum.group_by(changed, & &1.role)

        summary =
          Enum.map_join(by_role, ", ", fn {role, files} ->
            "#{role}(#{length(files)})"
          end)

        Logger.info(
          "[StopHook] [#{req_id}] Files changed during task: #{summary} — " <>
            Enum.map_join(changed, ", ", & &1.path)
        )
      else
        Logger.info("[StopHook] [#{req_id}] No files changed during task")
      end
    end

    # Step 4: Evaluate the active task
    result = TaskEvaluator.evaluate_sessions(scope, session_id)

    response =
      case result do
        {:ok, :valid} ->
          maybe_continue_with_next_task(scope, session, req_id)

        {:error, reason} when is_binary(reason) ->
          %{"decision" => "block", "reason" => reason}
      end

    json(conn, response)
  end

  defp maybe_continue_with_next_task(scope, session, req_id) do
    cond do
      is_nil(session) ->
        Logger.info("[StopHook] [#{req_id}] No session, allowing stop")
        notify_complete()
        %{}

      has_active_subagent_task?(session) ->
        Logger.info("[StopHook] [#{req_id}] Active subagent task, allowing stop")
        notify_complete()
        %{}

      has_active_manual_task?(session) ->
        Logger.info("[StopHook] [#{req_id}] Active manual task, allowing stop")
        notify_complete()
        %{}

      not continuous_mode?(session) ->
        Logger.info("[StopHook] [#{req_id}] Not in continuous mode, allowing stop")
        notify_complete()
        %{}

      true ->
        case RequirementGraph.next_actionable(scope) do
          [_ | _] ->
            Logger.info("[StopHook] [#{req_id}] Continuous mode, more work available, blocking stop")

            %{
              "decision" => "block",
              "reason" => """
              Task completed successfully. There is more work to do on this project.

              Call `get_next_requirement` to find your next assignment, then `start_task` to begin.
              """
            }

          [] ->
            Logger.info("[StopHook] [#{req_id}] All work complete, allowing stop")
            notify_complete()
            %{}
        end
    end
  end

  defp has_active_subagent_task?(session) do
    Enum.any?(session.tasks || [], fn task ->
      task.status == :active and task.execution_type == :sub_agent
    end)
  end

  defp continuous_mode?(%{state: %{"continuous" => true}}), do: true
  defp continuous_mode?(_), do: false

  defp has_active_manual_task?(session) do
    case Session.active_task(session) do
      %{validation_type: :manual} -> true
      _ -> false
    end
  end

  defp notify_complete do
    NotificationClient.notify(%{
      type: "task_complete",
      title: "Claude has finished",
      body: "Claude Code has completed its current task"
    })
  end
end
