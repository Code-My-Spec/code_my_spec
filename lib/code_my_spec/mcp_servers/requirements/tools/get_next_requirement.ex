defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement do
  @moduledoc """
  Get the next actionable requirement for the project.

  Returns the single highest-priority requirement that is unsatisfied, has all
  prerequisites met, and has a task module that can satisfy it.

  This is a read-only discovery tool — use it as a shortcut when you just want
  the next thing to work on. Call `start_task` with the returned requirement_id
  to begin work.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # Sync files + components before computing the graph.
        # `embed: false` because this is a read path — re-embedding the
        # framework knowledge corpus and re-projecting hex docs on every
        # `get_next_requirement` is the wrong coupling. The
        # `FileWatcherServer` boot pass + mix.lock-poll already keep the
        # embedding store fresh during a session. The explicit
        # `sync_project` MCP tool is the place for a manual full embed.
        if scope.cwd do
          FileSync.sync(scope, base_dir: scope.cwd, embed: false)
          FileComponentSync.sync_from_files(scope, base_dir: scope.cwd)
        end

        case RequirementGraph.next_actionable(scope) do
          [] -> {:reply, empty_response(scope), frame}
          nodes -> {:reply, RequirementsMapper.next_requirements_response(nodes), frame}
        end

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(frame)
        {:ok, prompt} = Init.command(scope, %{})
        {:reply, RequirementsMapper.init_required_response(prompt), frame}
    end
  end

  defp build_init_scope(frame) do
    working_dir = frame.assigns[:working_dir] || Validators.mcp_working_dir(frame)
    %{cwd: working_dir}
  end

  defp empty_response(scope) do
    case RequirementGraph.compute_all(scope) do
      [] -> RequirementsMapper.sync_required_response()
      _ -> RequirementsMapper.all_satisfied_response()
    end
  end
end
