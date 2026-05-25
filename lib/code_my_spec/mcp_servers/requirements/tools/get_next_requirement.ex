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
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

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

        # Resolve active sub-agents from the most recent session for this
        # project so the mapper can produce role-aware dispatch directives
        # (SendMessage to a live sub-agent vs. fresh Agent spawn).
        active_subagents = resolve_active_subagents(scope)

        case RequirementGraph.next_actionable(scope) do
          [] -> {:reply, empty_response(scope), frame}
          nodes -> {:reply, RequirementsMapper.next_requirements_response(nodes, active_subagents), frame}
        end

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(frame)
        {:ok, prompt} = Init.command(scope, %{})
        {:reply, RequirementsMapper.init_required_response(prompt), frame}
    end
  end

  # Resolves the currently-active sub-agents for the most recent session
  # on this project. Returns a map of role string → agent_id, e.g.
  # %{"qa" => "a-qa-spex-1"}. Used by the mapper to choose between
  # SendMessage (live agent) and Agent spawn (no live agent for role).
  defp resolve_active_subagents(scope) do
    ttl = Configurations.get_or_create(scope).subagent_ttl_minutes

    case Sessions.list_active_sessions(scope) do
      [] ->
        %{}

      [session | _] ->
        session
        |> Session.active_subagents(ttl)
        |> Map.new(fn subagent -> {subagent.agent_name, subagent.agent_id} end)
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
