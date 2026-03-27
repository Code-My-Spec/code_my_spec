defmodule CodeMySpec.LocalServer.Controllers.HookController do
  @moduledoc """
  Handles Claude Code hook events via HTTP.
  """

  require Logger

  alias CodeMySpec.Notifications.NotificationClient
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Validation

  @doc """
  Process a hook event.

  Expects JSON body with:
  - hook_event_name: "Stop" | "SubagentStop" | "PostToolUse"
  - session_id: Claude session ID
  - cwd: Current working directory (optional, also sent via header)
  """
  def handle(conn) do
    scope = conn.assigns[:current_scope]
    body = conn.body_params

    event_name = Map.get(body, "hook_event_name", "unknown")
    session_id = Map.get(body, "session_id")
    agent_id = Map.get(body, "agent_id")

    # Generate a request ID to correlate logs across the full hook lifecycle
    req_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    Logger.info(
      "[HookController] [#{req_id}] Event: #{event_name}, session: #{session_id}, agent: #{agent_id || "none"}, pid: #{inspect(self())}"
    )

    result = dispatch(scope, event_name, session_id, body, req_id)

    Logger.info("[HookController] [#{req_id}] Completed: #{inspect(Map.keys(result))}")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(result))
  end

  defp dispatch(scope, "Stop", session_id, hook_input, req_id) do
    transcript_path = Map.get(hook_input, "transcript_path")

    Logger.info("[HookController] [#{req_id}] Dispatching Stop handler")

    result =
      Validation.validate_stop(scope,
        transcript_path: transcript_path,
        session_id: session_id
      )

    case result do
      {:ok, :valid} ->
        maybe_continue_with_next_task(scope, session_id, req_id)

      _ ->
        Validation.format_output(result)
    end
  end

  defp dispatch(scope, "SubagentStop", _session_id, hook_input, req_id) do
    agent_id = Map.get(hook_input, "agent_id")
    agent_transcript_path = Map.get(hook_input, "agent_transcript_path")

    Logger.info(
      "[HookController] [#{req_id}] Dispatching SubagentStop handler, agent_id: #{agent_id || "none"}"
    )

    result = Validation.validate_subagent(scope, transcript_path: agent_transcript_path)

    Validation.format_output(result)
  end

  defp dispatch(_scope, "PostToolUse", _session_id, _hook_input, _req_id) do
    %{}
  end

  defp dispatch(_scope, "Notification", _session_id, hook_input, req_id) do
    notification_type = Map.get(hook_input, "notification_type", "info")
    title = Map.get(hook_input, "title", "Claude Code")
    message = Map.get(hook_input, "message", "")

    Logger.info("[HookController] [#{req_id}] Dispatching Notification: #{notification_type}")

    # Don't push generic notifications about permissions — the PermissionRequest
    # hook already sends a push with a link to the approval LiveView.
    if permission_notification?(title, message) do
      Logger.info("[HookController] [#{req_id}] Suppressing permission notification (handled by approve hook)")
    else
      Task.start(fn ->
        NotificationClient.notify(%{
          type: notification_type,
          title: title,
          body: message
        })
      end)
    end

    %{}
  end

  defp dispatch(_scope, "PreToolUse", _session_id, hook_input, req_id) do
    tool_name = Map.get(hook_input, "tool_name", "unknown")
    command = get_in(hook_input, ["tool_input", "command"]) || ""

    Logger.info("[HookController] [#{req_id}] PreToolUse #{tool_name}: #{String.slice(command, 0, 200)}")

    if tool_name == "Bash" and String.match?(command, ~r/mix test( |$)/) and
         not String.contains?(command, "mix agent_test") do
      replacement = String.replace(command, "mix test", "MIX_ENV=test mix agent_test")

      Logger.info("[HookController] [#{req_id}] Rewriting: #{String.slice(replacement, 0, 200)}")

      %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "allow",
          "permissionDecisionReason" => "Redirected mix test to mix agent_test",
          "updatedInput" => %{"command" => replacement}
        }
      }
    else
      Logger.info("[HookController] [#{req_id}] PreToolUse #{tool_name}: passthrough")
      %{}
    end
  end

  defp dispatch(_scope, event_name, _session_id, _hook_input, req_id) do
    Logger.warning("[HookController] [#{req_id}] Unhandled hook event: #{event_name}")
    %{}
  end

  # After validation passes, check if there's more work to do.
  # If so, block the stop and tell the agent to call next-task.
  # If not, let the agent stop and notify the user.
  defp maybe_continue_with_next_task(scope, session_id, req_id) do
    session = session_id && Sessions.get_by_external_id(scope, session_id)

    cond do
      # No session tracking — let it stop
      is_nil(session) ->
        Logger.info("[HookController] [#{req_id}] No session, allowing stop")
        notify_complete()
        %{}

      # Active sub_agent task — the subagent is still working, let main agent stop
      has_active_subagent_task?(session) ->
        Logger.info("[HookController] [#{req_id}] Active subagent task, allowing stop")
        notify_complete()
        %{}

      # Active manual validation task — user needs to act, let agent stop
      has_active_manual_task?(session) ->
        Logger.info("[HookController] [#{req_id}] Active manual task, allowing stop")
        notify_complete()
        %{}

      # Check if there's more work in the project
      true ->
        case ProjectCoordinator.get_next_actions(scope) do
          {:ok, _requirement} ->
            Logger.info("[HookController] [#{req_id}] More work available, blocking stop")

            slug = project_slug(scope.active_project)

            %{
              "decision" => "block",
              "reason" => """
              Task completed successfully. There is more work to do on this project.

              Call the next-task endpoint to get your next assignment:
              `curl -s http://localhost:4003/api/projects/#{slug}/next-task?session_id=#{session_id}`
              """
            }

          _ ->
            Logger.info("[HookController] [#{req_id}] No more work, allowing stop")
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

  defp project_slug(nil), do: "project"

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp permission_notification?(title, message) do
    text = String.downcase("#{title} #{message}")
    String.contains?(text, "permission") or String.contains?(text, "approval")
  end
end
