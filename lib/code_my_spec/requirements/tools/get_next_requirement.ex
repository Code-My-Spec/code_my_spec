defmodule CodeMySpec.Requirements.Tools.GetNextRequirement do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Requirements.Directives
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.Tools.Responses, as: RequirementsMapper

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

  # Seeding one copy's vantage loads ~5,000 file rows (0.4-1.3s idle); at 1s
  # every copy's discovery was refused while the projector sat idle. Still short
  # enough that a projector held through a restart rebuild answers quickly.
  @read_deadline_ms 2_500

  @impl true
  def call(params, context) do
    case IncrementalGraph.with_read_deadline(@read_deadline_ms, fn ->
           discover(params, context)
         end) do
      {:error, :graph_rebuilding} ->
        {:ok,
         "The requirement graph is being rebuilt or updated; retry in 5 s. No work was offered."}

      result ->
        result
    end
  end

  defp discover(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
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
          |> then(&Directives.number_execution(scope, &1))

        execution
        |> RequirementsMapper.story_execution_response(%{})
        |> with_decline_notes(agent, execution)
        |> with_offer_note(ready_offer(agent, execution.actionable))

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

  # A pull is a pure read: it never records an offer, only reports one it
  # already holds (issue e6f18e57, product's ruling: only pushed work turns
  # climb the ladder). `reject_offer`'s own fallback handles the case this
  # agent was shown work with no offer behind it at all.
  #
  # Only an offer for work shown here is named: one recorded before the team
  # moved story, or before its requirement stopped being actionable, would
  # send the agent to a `start_task` that refuses it.
  defp ready_offer(%{id: agent_id}, actionable) when is_binary(agent_id) do
    case Offers.current_work_offer(agent_id) do
      %{subject_type: "requirement", subject_key: key} = offer ->
        if Enum.any?(actionable, &(offer_key(&1) == key)), do: offer

      offer ->
        offer
    end
  end

  defp ready_offer(_agent, _actionable), do: nil

  # The key `Work` records an offer under: a story by number, else by id.
  defp offer_key(node), do: "#{node.entity_type}:#{Directives.entity_ref(node)}:#{node.name}"

  defp with_decline_notes(response, nil, _execution), do: response

  defp with_decline_notes({:ok, text}, agent, execution) do
    notes = Offers.decline_notes(agent.id, execution.wave)
    {:ok, text <> notes}
  end

  defp with_offer_note(response, nil), do: response

  defp with_offer_note({:ok, text}, offer) do
    {:ok,
     text <>
       "\n\nThis is backed by offer `#{offer.id}`. Complete it, or call " <>
       "`reject_offer` with that id and a reason."}
  end

  defp my_agent(context, scope) do
    with agent_id when is_binary(agent_id) <- context[:agent_id],
         {:ok, agent} <- Agents.fetch_agent(scope, agent_id) do
      agent
    else
      _ -> nil
    end
  end

  defp build_init_scope(context) do
    working_dir = context[:working_dir] || CodeMySpec.WorkingCopies.configured_working_dir()

    %{cwd: working_dir}
  end
end
