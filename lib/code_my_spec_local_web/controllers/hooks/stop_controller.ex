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
    validation_opts = extract_test_output_files(params)

    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Logger.info("[StopHook] [#{req_id}] session: #{session_id}")

    session = session_id && Sessions.get_by_external_id(scope, session_id)
    active_task = session && Session.active_task(session)

    response = decide(scope, session_id, session, active_task, validation_opts, req_id)

    json(conn, response)
  end

  defp decide(scope, session_id, session, active_task, validation_opts, req_id) do
    cond do
      session && has_active_subagent_task?(session) ->
        allow(req_id, "Active subagent task")

      session && has_active_manual_task?(session) ->
        allow(req_id, "Active manual task")

      true ->
        run_and_decide(scope, session_id, session, active_task, validation_opts, req_id)
    end
  end

  defp run_and_decide(scope, session_id, session, active_task, validation_opts, req_id) do
    with {:ok, _result} <- Validation.validate_stop(scope, active_task, validation_opts),
         {:ok, :valid} <- maybe_evaluate(scope, session_id, session) do
      maybe_continue_with_next_task(scope, session, req_id)
    else
      {:error, reason} ->
        Logger.info("[StopHook] [#{req_id}] Blocking: #{String.slice(reason, 0, 100)}")
        %{"decision" => "block", "reason" => reason}
    end
  end

  defp allow(req_id, label) do
    Logger.info("[StopHook] [#{req_id}] #{label}, allowing stop")
    notify_complete()
    %{}
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

  # Test-only: specs back pipeline outputs with pre-recorded JSON fixtures
  # so cassette replays can observe failures (`System.cmd` side effects —
  # the JSON output files — can't be captured by ExCliVcr alone).
  # Real Claude Code clients never send this param; the map is ignored
  # when absent.
  defp extract_test_output_files(%{"test_output_files" => files}) when is_map(files) do
    [
      compile_output_file: Map.get(files, "compile"),
      exunit_output_file: Map.get(files, "exunit"),
      spex_output_file: Map.get(files, "spex")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp extract_test_output_files(_params), do: []

  defp notify_complete do
    NotificationClient.notify(%{
      type: "task_complete",
      title: "Claude has finished",
      body: "Claude Code has completed its current task"
    })
  end
end
