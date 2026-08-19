defmodule CodeMySpecLocalWeb.SkillController do
  @moduledoc """
  Single entry point for skill and agent task invocations.

  Two actions:
  - `start_skill/2` — routes skill + subcommand to the right session type
  - `start_task/2`  — accepts session_type directly (used by bin/agent-task)

  `start_skill/2` delegates the routing itself to `SkillRouter.resolve/2` —
  see that module's moduledoc for why it isn't inline here anymore.
  `start_task/2` still calls `StartAgentTask.run/2` directly: it takes
  `session_type` as given rather than resolving one from a skill name, so
  there is no routing table to share.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.SkillRouter
  alias CodeMySpec.AgentTasks.StartAgentTask

  # ── Skill routing (POST /api/skills/start) ──────────────────────

  def start_skill(conn, params) do
    case SkillRouter.resolve(conn.assigns.current_scope, params) do
      {:ok, %{stopped: true}} ->
        json(conn, %{stopped: true})

      {:ok, result} ->
        json(conn, result)

      {:error, reason, available} ->
        conn |> put_status(400) |> json(%{error: reason, available: available})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: reason})
    end
  end

  # ── Direct task dispatch (POST /api/agent-tasks/start) ──────────

  def start_task(conn, params) do
    run_task(conn, params["external_id"], params["session_type"], params["module_name"])
  end

  defp run_task(conn, external_id, session_type, module_name) do
    scope = conn.assigns.current_scope

    args = %{
      external_id: external_id,
      session_type: session_type,
      module_name: module_name
    }

    case StartAgentTask.run(scope, args) do
      {:ok, prompt, _sync_result} ->
        json(conn, %{prompt: prompt})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end
end
