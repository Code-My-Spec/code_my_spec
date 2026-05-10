defmodule CodeMySpecLocalWeb.SkillController do
  @moduledoc """
  Single entry point for skill and agent task invocations.

  Two actions:
  - `start_skill/2` — routes skill + subcommand to the right session type
  - `start_task/2`  — accepts session_type directly (used by bin/agent-task)

  Both delegate to StartAgentTask.run for the actual work.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.StartAgentTask
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync

  # skill → {subcommand → session_type}
  # nil subcommand means "no args" default
  @skill_routes %{
    "product" => %{
      "interview" => "story_interview",
      "review" => "story_review",
      "three-amigos" => "three_amigos"
    },
    "init" => %{
      nil => "init"
      # "auth" and "sync" handled as special routes
    },
    "design" => %{
      "architecture" => "architecture_design",
      "ui" => "design_ui",
      "strategy" => "technical_strategy"
    },
    "develop" => %{
      "context" => "develop_context",
      "liveview" => "develop_live_view"
    },
    "qa" => %{
      nil => "qa_app",
      "story" => "qa_story",
      "integrations" => "qa_integration_plan",
      "triage" => "triage_issues",
      "fix" => "fix_issues"
    },
    "implement" => %{
      nil => "start_implementation",
      "start" => "start_implementation"
    },
    # "sync" handled as a special route (not an agent task)
    "sync" => %{}
  }

  # ── Skill routing (POST /api/skills/start) ──────────────────────

  def start_skill(conn, %{"skill" => skill} = params) do
    subcommand = params["subcommand"]
    module_name = params["module_name"]
    external_id = params["external_id"]

    case resolve_route(skill, subcommand) do
      {:ok, :sync} ->
        run_sync(conn)

      {:ok, :next} ->
        run_next(conn)

      {:ok, session_type} ->
        run_task(conn, external_id, session_type, module_name)

      {:error, :auth} ->
        json(conn, %{auth: true})

      {:error, :stopped} ->
        json(conn, %{stopped: true})

      {:error, :unknown_skill} ->
        conn |> put_status(400) |> json(%{error: "Unknown skill: #{skill}"})

      {:error, :unknown_subcommand, available} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "Unknown subcommand '#{subcommand}' for /codemyspec:#{skill}",
          available: available
        })
    end
  end

  # ── Direct task dispatch (POST /api/agent-tasks/start) ──────────

  def start_task(conn, params) do
    run_task(conn, params["external_id"], params["session_type"], params["module_name"])
  end

  # ── Route resolution ────────────────────────────────────────────

  defp resolve_route("init", "auth"), do: {:error, :auth}
  defp resolve_route("init", "sync"), do: {:ok, :sync}
  defp resolve_route("sync", nil), do: {:ok, :sync}
  defp resolve_route("implement", "stop"), do: {:error, :stopped}
  defp resolve_route("next", _), do: {:ok, :next}

  defp resolve_route(skill, subcommand) do
    case Map.get(@skill_routes, skill) do
      nil ->
        {:error, :unknown_skill}

      routes ->
        case Map.get(routes, subcommand) do
          nil when is_nil(subcommand) -> {:error, :unknown_subcommand, Map.keys(routes) -- [nil]}
          nil -> {:error, :unknown_subcommand, Map.keys(routes) -- [nil]}
          session_type -> {:ok, session_type}
        end
    end
  end

  # ── Task execution ─────────────────────────────────────────────

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

  defp run_sync(conn) do
    scope = conn.assigns.current_scope

    with {:ok, cwd} <- validate_cwd(scope),
         {:ok, file_result} <- FileSync.sync(scope, base_dir: cwd),
         {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: cwd) do
      files = file_result.total_files
      changed = length(file_result.changed_paths)
      components = length(comp_result.all_components)

      prompt = """
      Sync complete. #{files} files (#{changed} changed), #{components} components.

      Call `get_next_requirement` to find your next task.
      """

      json(conn, %{prompt: prompt})
    else
      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: "Sync failed: #{inspect(reason)}"})
    end
  end

  defp validate_cwd(%{cwd: cwd}) when is_binary(cwd), do: {:ok, cwd}
  defp validate_cwd(_), do: {:error, "No working directory set. Send X-Working-Dir header."}

  # ── /next ───────────────────────────────────────────────────────
  # Single-step "do the next requirement" gesture. Resolves the next
  # actionable requirement on the server so the agent gets the full
  # context inline and can call `start_task` directly — saves a
  # roundtrip over chaining `get_next_requirement` → `start_task`,
  # and gives the user immediate visibility into what's coming next.
  defp run_next(conn) do
    scope = conn.assigns.current_scope

    cond do
      scope == nil or scope.active_project == nil ->
        json(conn, %{
          prompt: """
          No active project linked locally. Run `/codemyspec:init` to bootstrap, \
          or visit http://localhost:4003 to pick a project.
          """
        })

      true ->
        next_prompt(conn, scope)
    end
  end

  defp next_prompt(conn, scope) do
    if scope.cwd do
      FileSync.sync(scope, base_dir: scope.cwd)
      FileComponentSync.sync_from_files(scope, base_dir: scope.cwd)
    end

    case CodeMySpec.Requirements.RequirementGraph.next_actionable(scope) do
      [] ->
        case CodeMySpec.Requirements.RequirementGraph.compute_all(scope) do
          [] ->
            json(conn, %{
              prompt: "No requirements found. Run `/codemyspec:sync` to refresh the graph."
            })

          _ ->
            json(conn, %{
              prompt: "✓ All requirements satisfied. Nothing left to do on this project."
            })
        end

      [node | _] ->
        json(conn, %{prompt: render_next_prompt(node)})
    end
  end

  defp render_next_prompt(node) do
    """
    # Next: #{node.name}

    Your next task is **#{node.name}** for #{node.entity_type} `#{node.entity_name}`.

    Call `start_task` with:
    - `requirement_name`: `"#{node.name}"`
    - `entity_type`: `"#{node.entity_type}"`
    - `entity_id`: `"#{node.entity_id}"`

    `start_task` returns the work prompt for this requirement. Do the work,
    then run `/next` again for the following task.
    """
  end
end
