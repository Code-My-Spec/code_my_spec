defmodule CodeMySpec.Requirements.Tools.GetNextRequirement do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Configurations
  alias CodeMySpec.Requirements.Tools.Responses, as: RequirementsMapper
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  @impl true
  def name, do: "get_next_requirement"

  @impl true
  def description do
    """
    Discover the next orchestration wave for the story the working copy's team
    (its coding and QA agents) holds.

    Discovery never selects another story. An explicit story must agree with that
    assignment. Use `start_task` on offered requirements.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:meta, :integer, [description: "Optional story number; must match your active story"]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        # Resolve active sub-agents from the most recent session for this
        # project so the mapper can produce role-aware dispatch directives
        # (SendMessage to a live sub-agent vs. fresh Agent spawn).
        active_subagents = resolve_active_subagents(scope)

        # One normalisation rather than two lookups: the schema declares atom
        # keys and a raw MCP payload arrives with strings, so both shapes reach
        # here and only one of them should be asked about.
        requested = Map.new(params, fn {k, v} -> {to_string(k), v} end)

        agent = my_agent(context, scope)

        # The head of the same list the turn offer and the stop menu read
        # (a31f1cd6); what `start_task` would refuse is withheld (467310a7).
        execution =
          scope
          |> Work.work_for(agent && agent.role, agent, story_number: requested["story_number"])
          |> then(&CodeMySpec.Requirements.Directives.number_execution(scope, &1))

        RequirementsMapper.story_execution_response(execution, active_subagents)

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(context)
        {:ok, prompt} = Init.command(scope, %{})
        RequirementsMapper.init_required_response(prompt)
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
  # Nothing is lost. Files reach the graph incrementally: the harness manifest
  # reconciles changed paths, and `FileSync.sync_changed/2` runs in the
  # validation path. The Files page's Sync button remains the
  # deliberate full pass.

  defp my_agent(context, scope) do
    with agent_id when is_binary(agent_id) <- context[:agent_id],
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

  defp build_init_scope(context) do
    working_dir = context[:working_dir] || CodeMySpec.WorkingCopies.configured_working_dir()

    %{cwd: working_dir}
  end
end
