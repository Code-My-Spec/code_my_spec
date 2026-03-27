defmodule CodeMySpecLocalWeb.Hooks.StopController do
  @moduledoc """
  Handles the Stop hook event.

  Validates the session transcript and checks if there's more work to do.
  Blocks the stop if actionable tasks remain, directing the agent to draft_task.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")
    transcript_path = Map.get(params, "transcript_path")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    result =
      Validation.validate_stop(scope,
        transcript_path: transcript_path,
        session_id: session_id
      )

    response =
      case result do
        {:ok, :valid} ->
          maybe_continue_with_next_task(scope, session_id, req_id)

        _ ->
          Validation.format_output(result)
      end

    json(conn, response)
  end

  defp maybe_continue_with_next_task(scope, session_id, req_id) do
    session = session_id && Sessions.get_by_external_id(scope, session_id)

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

      true ->
        case Requirements.next_actionable_project(scope) do
          [_ | _] ->
            Logger.info("[StopHook] [#{req_id}] More work available, blocking stop")

            %{
              "decision" => "block",
              "reason" => """
              Task completed successfully. There is more work to do on this project.

              Call `draft_task` to get your next assignment.
              """
            }

          [] ->
            Logger.info("[StopHook] [#{req_id}] No more work, allowing stop")
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

  defp has_active_manual_task?(session) do
    case Session.active_task(session) do
      %{validation_type: :manual} -> true
      _ -> false
    end
  end

  defp notify_complete do
    Task.start(fn ->
      NotificationClient.notify(%{
        type: "task_complete",
        title: "Claude has finished",
        body: "Claude Code has completed its current task"
      })
    end)
  end
end
