defmodule CodeMySpec.LocalServer.Controllers.HookController do
  @moduledoc """
  Handles Claude Code hook events via HTTP.
  """

  require Logger

  alias CodeMySpec.AgentTasks.{EvaluateAgentTask, TrackEdits, ValidateEdits}
  alias CodeMySpec.Projects.Lifecycle

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
    cwd = Map.get(body, "cwd") || conn.assigns[:working_dir]

    Logger.info("[HookController] Event: #{event_name}, session: #{session_id}")

    result = dispatch(scope, event_name, session_id, cwd, body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(result))
  end

  defp dispatch(scope, "Stop", session_id, cwd, _hook_input) do
    # Always run ValidateEdits
    validate_result = dispatch_validate_edits(session_id, cwd)

    # Evaluate the session stack
    eval_result = EvaluateAgentTask.run(scope)

    # Run Lifecycle check if agentic_mode is enabled
    lifecycle_result = dispatch_lifecycle_check(scope, cwd)

    # Merge all results
    validate_result
    |> merge_hook_results(eval_result)
    |> merge_hook_results(lifecycle_result)
  end

  defp dispatch(_scope, "SubagentStop", session_id, cwd, _hook_input) do
    dispatch_validate_edits(session_id, cwd)
  end

  defp dispatch(_scope, "PostToolUse", _session_id, _cwd, hook_input) do
    TrackEdits.run(hook_input)
  end

  defp dispatch(_scope, event_name, _session_id, _cwd, _hook_input) do
    Logger.warning("[HookController] Unhandled hook event: #{event_name}")
    %{}
  end

  defp dispatch_validate_edits(nil, _cwd) do
    Logger.warning("[HookController] No session_id, skipping validation")
    %{}
  end

  defp dispatch_validate_edits(session_id, cwd) do
    opts = if cwd, do: [working_dir: cwd], else: []

    session_id
    |> ValidateEdits.run(opts)
    |> ValidateEdits.format_output()
  end

  defp dispatch_lifecycle_check(nil, _cwd), do: %{}

  defp dispatch_lifecycle_check(scope, cwd) do
    project = scope.active_project

    if project && project.agentic_mode do
      Logger.info("[HookController] Agentic mode enabled, running lifecycle check")
      opts = if cwd, do: [working_dir: cwd], else: []

      scope
      |> Lifecycle.evaluate(opts)
      |> Lifecycle.format_hook_result(scope)
    else
      %{}
    end
  end

  defp merge_hook_results(result1, result2) do
    case {result1["decision"], result2["decision"]} do
      {"block", "block"} ->
        %{
          "decision" => "block",
          "reason" => "#{result1["reason"]}\n\n#{result2["reason"]}"
        }

      {"block", _} ->
        result1

      {_, "block"} ->
        result2

      _ ->
        Map.merge(result1, result2)
    end
  end
end
