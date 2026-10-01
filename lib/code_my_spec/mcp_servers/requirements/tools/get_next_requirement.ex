defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement do
  @moduledoc """
  Discover the next orchestration wave for this working copy's active story.

  Discovery never selects another story. An explicit story must agree with the
  working copy's active assignment. Use `start_task` on offered requirements.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.StoryRefs
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :story_number, :integer,
      doc: "Optional story number; must match this working copy's active story"
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # Resolve active sub-agents from the most recent session for this
        # project so the mapper can produce role-aware dispatch directives
        # (SendMessage to a live sub-agent vs. fresh Agent spawn).
        active_subagents = resolve_active_subagents(scope)

        # One normalisation rather than two lookups: the schema declares atom
        # keys and a raw MCP payload arrives with strings, so both shapes reach
        # here and only one of them should be asked about.
        requested = Map.new(params, fn {k, v} -> {to_string(k), v} end)

        agent = my_agent(frame, scope)

        # The head of the same list the turn offer and the stop menu read
        # (a31f1cd6); what `start_task` would refuse is withheld (467310a7).
        execution =
          scope
          |> Work.work_for(agent && agent.role, agent, story_number: requested["story_number"])
          |> then(&StoryRefs.number_execution(scope, &1))

        {:reply, RequirementsMapper.story_execution_response(execution, active_subagents), frame}

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(frame)
        {:ok, prompt} = Init.command(scope, %{})
        {:reply, RequirementsMapper.init_required_response(prompt), frame}
    end
  end

  # This is a read. It does not sync.
  #
  # It used to run a full `FileSync.sync/2` plus `ComponentSync.sync_from_files/2`
  # first, and that was already known to be expensive — narrowed once by
  # threading `changed_paths`, after a full resync of every component on every
  # call (1067 components, ~2100 UPDATEs, 7-25s) became the dominant load on a
  # large project and perpetually invalidated the graph cache.
  #
  # The reason to remove it rather than narrow it again is correctness, not
  # cost. `Agents.Work` decides whether to wake an agent by
  # reading the graph directly, with no sync. Syncing here meant admission and
  # the agent's own first question were answered from two different graphs, so
  # an agent could be woken for work that had moved by the time it asked —
  # measured as `main: ["technical_strategy"]` at admission and
  # `bdd_specs_passing` (coding) one turn later. Issue c83c5b58.
  #
  # Nothing is lost. Files reach the graph incrementally: `FileWatcherServer`
  # drives `ProjectSync.Sync` per changed path, and `FileSync.sync_changed/2`
  # runs in the validation path. The Files page's Sync button remains the
  # deliberate full pass.

  defp my_agent(frame, scope) do
    with agent_id when is_binary(agent_id) <- frame.assigns[:agent_id],
         {:ok, agent} <- Agents.fetch_agent(scope, agent_id) do
      agent
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
