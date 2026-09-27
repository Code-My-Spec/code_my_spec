defmodule CodeMySpec.Analysis.AgentReport do
  @moduledoc """
  Tell the agents in a working copy that their analysis has landed.

  The internal half of story 1042. There are two consumers of an analyzer
  result and they are not variations of one thing:

    * An **external** agent — Claude Code — keeps running and fires hooks. It is
      offered a wait endpoint, and the digest reaches it on `PostToolUse` via
      `Hooks.AnalysisAlert`. That path is a *pull*: the agent's next tool call
      collects it.

    * An **internal** agent — Alloy, in our own BEAM — has a process we can
      reach. It should start a run, end its turn, and be told when the run is
      done. That is a *push*, and it is this module.

  John, when the internal agent was found waiting on a `curl` instead: "the
  analysis tool is different for the Alloy agent — when we run analysis, the
  agent should stop, we should run analysis, and then when it's done running
  analysis it should message the Alloy agent back."

  ## Why the wording differs from the hook's

  `Alert.message/2` is capped at 199 characters, and its own comment says why:
  "it rides on every tool call in every turn, so the budget is a sentence."
  That is the *hook's* budget, not a message's. A push costs one delivery, so
  it can carry the counts by source and say what to do next — which is the
  difference between "something is failing" and something the agent can act on
  without a round trip.

  ## Silence is a result, except to whoever asked

  A clean run says nothing (criterion 3046). A message wakes a process and
  costs it a turn, and an agent woken to be told its tree is fine has been
  charged for no information — the same rule `StopDecision` keeps everywhere.

  That holds for an agent that did not ask. For the agent that *requested* the
  run, silence is not the absence of information, it is the answer it is
  blocked on — and `runs.requested_by` already records who that is.

  Measured on the math project 2026-09-22: a coding agent called
  `start_analysis(spex)`, said "not polling; will act when it lands", and its
  run came back green. `digest/2` answers `nil` for a clean tree, so nothing was
  sent. The agent held an open `bdd_specs_passing` task for 25 minutes, and
  `Work.runnable_state?/1` skips an agent with an open task — so no wake path in
  the system could reach it. A human had to tell it the run was green. Three
  times in one session, 22 to 26 minutes each.

  So `deliver/4` takes the requester\'s id: everyone else keeps the silence,
  and the one who asked gets an answer either way.

  Delivery is dispatched, never called: `message_agent/4` runs the whole turn
  inside a `GenServer.call`, and this runs inside the reconciler, which must not
  wait out an agent's reply to finish recording a run.

  An agent with no process is not owed delivery and is not a failure
  (criterion 3049). `dispatch_message` answers `{:error, :not_running}` and this
  drops it — an agent halted on purpose is not news anybody is waiting for.
  """

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  import Ecto.Query

  @doc """
  Tell every internal agent in this run's working copy what landed.

  Answers `:ok` regardless. This runs at the end of `Reconciler.reconcile/4`,
  where the run has already been recorded — a delivery that fails must not make
  a completed run look incomplete.
  """
  @spec deliver(Scope.t(), atom() | String.t(), [struct()], String.t() | nil) :: :ok
  def deliver(scope, source, problems, requester_id \\ nil)

  def deliver(%Scope{active_working_copy_id: copy_id} = scope, source, problems, requester_id)
      when is_binary(copy_id) do
    findings = digest(source, problems)
    requester_id = agent_uuid(requester_id)

    scope
    |> internal_agents(copy_id, requester_id)
    |> Enum.each(&tell_one(&1, findings, source, requester_id))
  end

  def deliver(_scope, _source, _problems, _requester_id), do: :ok

  # `requested_by["agent_id"]` carries two kinds of id. `start_analysis` stores an
  # in-app agent's UUID; the `subagent_stop` hook stores a Claude Code subagent
  # id, which is short hex (`af6cbaec65372da7a`) and is never an `agents` row.
  # Queried as `:binary_id` the second raised, failing the reconcile — so a leg
  # recorded as failed a run that had completed, which is the one thing this
  # module says it must not do. Only a UUID can name an agent here.
  defp agent_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp agent_uuid(_id), do: nil

  # The asker is answered whatever the run found; everyone else keeps the
  # silence a clean tree earns them.
  defp tell_one(%{id: id} = agent, findings, source, id),
    do: tell(agent, findings || clean(source))

  defp tell_one(_agent, nil, _source, _requester_id), do: :ok
  defp tell_one(agent, findings, _source, _requester_id), do: tell(agent, findings)

  defp clean(source) do
    """
    Your #{source} run finished: no problems in this working copy.

    This is the answer to the run you started, not a nudge — nothing here needs
    fixing. If a task was waiting on it, dispose of that task now rather than
    waiting further.
    """
  end

  # Alloy only. A Claude Code session in the same copy has its own path and
  # would be told twice — once here and once on its next tool call — which is
  # the duplicate criterion 3048 exists to keep out.
  # The roles a run's findings are actually for.
  #
  # `Validation.Menu` holds the same two on its problems class, and for the same
  # reason: `:coding` fixes code and `:main` does everything, while `:qa` tests a
  # story and `:product` writes specs. Telling QA about 47 spex errors it cannot
  # read — the digest says "call `list_problems`", which its role does not carry
  # — is a message that costs a turn and offers no move.
  #
  # Kept beside the menu's list deliberately rather than shared: they answer
  # different questions that happen to agree today, and a wake that follows a
  # refusal it cannot cause is worse than two lists that drift visibly.
  @report_roles [:coding, :main]

  # Two questions, and this used to answer both with the role list.
  #
  # "Who should hear about findings nobody asked for" is a broadcast, and the
  # roles above are the right answer to it. "Who asked for this run and is
  # waiting on it" is a reply, and the asker's role has nothing to do with it —
  # `tell_one/4` already knows the difference and answers the requester whatever
  # the run found, including a clean one. That clause could never fire for a role
  # outside the list, because this query removed the asker before it ran.
  #
  # Measured 2026-09-23. A QA agent on Broken Oaths story 947 started credo and
  # spex through `start_analysis`, both rows carrying
  # `requested_by: {"agent_id" => "b55ec59c-..."}`. Both completed at 16:02. It
  # held its task waiting for them, correctly, and was never told: `:qa` is not
  # in `@report_roles`, so it was filtered out of its own answer. Fifty minutes,
  # and the only thing that moved it was a person noticing.
  #
  # The broadcast filter is unchanged and still right — the comment above it
  # describes a real cost, and a QA agent still does not get told about 47 spex
  # errors it cannot read. It just no longer decides who may be answered.
  # `requester_id` is `run.requested_by["agent_id"]`, written by whoever called
  # `start_analysis` — an alloy agent's real row id, but a Claude Code session
  # writes its own (non-UUID) session id there instead, having no row in this
  # table at all. `is_binary/1` accepts either, and `a.id == ^requester_id`
  # then asks Ecto to dump a non-UUID string as this column's `:binary_id`,
  # which raises and fails the whole run's report — not silently: it crashes
  # every analysis a CLI session requests, compiler and credo included.
  # Casting first turns "not a real agent id" back into the plain broadcast
  # this session was always going to get told through its own path anyway (see
  # "Alloy only" above).
  defp internal_agents(%Scope{} = scope, copy_id, requester_id) when is_binary(requester_id) do
    case Ecto.UUID.cast(requester_id) do
      {:ok, agent_id} -> internal_agents_matching(scope, copy_id, agent_id)
      :error -> internal_agents(scope, copy_id, nil)
    end
  end

  defp internal_agents(%Scope{active_project_id: project_id}, copy_id, _requester_id) do
    Agent
    |> where(
      [a],
      a.working_copy_id == ^copy_id and a.project_id == ^project_id and
        a.status != :stopped and a.engine == :alloy and a.role in ^@report_roles
    )
    |> Repo.all()
  end

  defp internal_agents_matching(%Scope{active_project_id: project_id}, copy_id, agent_id) do
    Agent
    |> where(
      [a],
      a.working_copy_id == ^copy_id and a.project_id == ^project_id and
        a.status != :stopped and a.engine == :alloy and
        (a.role in ^@report_roles or a.id == ^agent_id)
    )
    |> Repo.all()
  end

  defp tell(%Agent{} = agent, message) do
    ref = "analysis-" <> Ecto.UUID.generate()

    case Transport.impl().dispatch_message(agent.working_copy_id, agent, ref, message, 10_000) do
      {:ok, _disposition} ->
        :ok

      # Not a warning. Nobody to tell is an ordinary state — the agent was
      # stopped — and logging it as a failure is what criterion 3049 forbids.
      {:error, :not_running} ->
        :ok

      {:error, reason} ->
        Logger.info(
          "[Analysis] could not tell agent #{agent.id} about the run: #{inspect(reason)}"
        )

        :ok
    end
  end

  # What landed, by source, and what to do about it. `nil` when there is nothing
  # worth waking anyone for.
  defp digest(source, problems) do
    case Enum.count(problems, &(&1.severity == :error)) do
      0 ->
        nil

      count ->
        """
        Your #{source} run finished: #{count} #{noun(count)} in this working copy.

        Call `list_problems` for the detail. If they are yours, fix them and run
        the analyzers again; if the run says something you have already fixed,
        it measured the tree before your edit and the next one will disagree
        with it.
        """
    end
  end

  defp noun(1), do: "problem"
  defp noun(_), do: "problems"
end
