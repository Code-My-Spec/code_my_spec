defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement do
  @moduledoc """
  Discover the next orchestration wave for this working copy's active story.

  Discovery never selects another story. An explicit story must agree with the
  working copy's active assignment. Use `start_task` on offered requirements.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :story_id, :string,
      doc: "Optional story id; must match this working copy's active story"
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        sync_files(scope)

        # Resolve active sub-agents from the most recent session for this
        # project so the mapper can produce role-aware dispatch directives
        # (SendMessage to a live sub-agent vs. fresh Agent spawn).
        active_subagents = resolve_active_subagents(scope)

        # One normalisation rather than two lookups: the schema declares atom
        # keys and a raw MCP payload arrives with strings, so both shapes reach
        # here and only one of them should be asked about.
        requested = Map.new(params, fn {k, v} -> {to_string(k), v} end)

        execution =
          Requirements.story_execution(scope, my_role(frame, scope), requested["story_id"])

        {:reply, RequirementsMapper.story_execution_response(execution, active_subagents), frame}

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(frame)
        {:ok, prompt} = Init.command(scope, %{})
        {:reply, RequirementsMapper.init_required_response(prompt), frame}
    end
  end

  # Sync files + components before computing the graph.
  # `embed: false` because this is a read path — re-embedding the framework
  # knowledge corpus and re-projecting hex docs on every `get_next_requirement`
  # is the wrong coupling. The `FileWatcherServer` boot pass + mix.lock-poll
  # already keep the embedding store fresh during a session. The explicit
  # `sync_project` MCP tool is the place for a manual full embed.
  #
  # `changed_paths` threaded through to `ComponentSync`, matching
  # `AgentTasks.Evaluator.sync_files/1` — without it, this scoped every single
  # call to a full, non-incremental resync of every component in the project
  # (1067 components, ~2100 raw UPDATEs, 7-25s) regardless of whether this
  # call's own scan found anything to change. Called once per agent loop
  # iteration, that was the dominant source of load on a large project, and it
  # also perpetually invalidated the requirements graph cache by marking every
  # component "changed" on every call.
  defp sync_files(%{cwd: nil}), do: :ok

  defp sync_files(%{cwd: cwd} = scope) do
    case FileSync.sync(scope, base_dir: cwd, embed: false) do
      {:ok, file_result} ->
        FileComponentSync.sync_from_files(scope,
          base_dir: cwd,
          changed_paths: file_result.changed_paths,
          removed_module_names: file_result.removed_module_names
        )

      {:error, _reason} ->
        :ok
    end
  end

  defp my_role(frame, scope) do
    with agent_id when is_binary(agent_id) <- frame.assigns[:agent_id],
         {:ok, %{role: role}} <- Agents.fetch_agent(scope, agent_id) do
      role
    else
      _ -> nil
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
end
