defmodule CodeMySpecLocalWeb.Hooks.StopController do
  @moduledoc """
  Handles the Stop hook event.

  Thin HTTP layer: resolves session/task, calls Validation (sync + compile +
  analyze), calls TaskEvaluator (pure DB read), decides block/allow.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation
  alias CodeMySpec.Validation.TaskEvaluator

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    session_id = Map.get(params, "session_id")

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    # Step 1: Resolve session + task
    session = session_id && Sessions.get_by_external_id(scope, session_id)
    active_task = session && Session.active_task(session)

    # Step 2: Skip everything for subagent tasks
    response =
      cond do
        session && has_active_subagent_task?(session) ->
          Logger.info("[StopHook] [#{req_id}] Active subagent task, allowing stop")
          notify_complete()
          %{}

        session && has_active_manual_task?(session) ->
          Logger.info("[StopHook] [#{req_id}] Active manual task, allowing stop")
          notify_complete()
          %{}

        true ->
          # Step 3: Run validation pipeline (sync + compile + analyze + tests)
          case Validation.validate_stop(scope, active_task) do
            {:error, reason} ->
              Logger.info("[StopHook] [#{req_id}] Validation blocked: #{String.slice(reason, 0, 100)}")
              %{"decision" => "block", "reason" => reason}

            {:ok, _result} ->
              # Step 4: Evaluate task requirements (pure DB read)
              case maybe_evaluate(scope, session_id, session) do
                {:error, reason} ->
                  %{"decision" => "block", "reason" => reason}

                {:ok, :valid} ->
                  maybe_continue_with_next_task(scope, session, req_id)
              end
          end
      end

    json(conn, response)
  end

  defp maybe_evaluate(_scope, _session_id, nil), do: {:ok, :valid}

  defp maybe_evaluate(scope, session_id, _session) do
    TaskEvaluator.evaluate_sessions(scope, session_id)
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

  defp maybe_continue_with_next_task(scope, session, req_id) do
    cond do
      is_nil(session) ->
        Logger.info("[StopHook] [#{req_id}] No session, allowing stop")
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

  defp continuous_mode?(%{state: %{"continuous" => true}}), do: true
  defp continuous_mode?(_), do: false

  defp notify_complete do
    NotificationClient.notify(%{
      type: "task_complete",
      title: "Claude has finished",
      body: "Claude Code has completed its current task"
    })
  end
end
