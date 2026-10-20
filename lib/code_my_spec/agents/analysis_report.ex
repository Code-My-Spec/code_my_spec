defmodule CodeMySpec.Agents.AnalysisReport do
  @moduledoc """
  Tell the agents in a working copy that their analysis has landed.

  The push half for internal (Alloy) agents: an agent starts a run, ends its
  turn, and is messaged when the run lands.

  A clean run says nothing to agents that did not ask; the agent that
  requested the run (or is waiting on it) is answered either way, because
  silence is the answer it is blocked on. Delivery enters the durable mailbox
  without waiting for the agent's turn; an agent with no process is not owed
  one.

  Attached as a telemetry handler on `[:code_my_spec, :analysis, :run_reported]`
  so `Analysis` does not depend on `Agents`; it runs synchronously in the
  emitting reconciler.

  See knowledge/agents/coordination, "Analysis reports".
  """

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Blocking

  import Ecto.Query

  @event [:code_my_spec, :analysis, :run_reported]

  @doc "The event `Analysis` emits when a run's findings are recorded."
  def event, do: @event

  @doc "Attach the handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach({__MODULE__, :deliver}, @event, &__MODULE__.handle_event/4, nil)
  end

  # Rescued and logged at error: `:telemetry` permanently detaches a handler
  # that raises, so one bad delivery would silently end every later one.
  @doc false
  def handle_event(@event, _measurements, %{failure: reason} = meta, _config) do
    deliver_failure(meta.scope, meta.source, reason, askers(meta))
  rescue
    e ->
      Logger.error(
        "[AnalysisReport] delivering #{meta.source} failure failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end

  def handle_event(@event, _measurements, meta, _config) do
    deliver(meta.scope, meta.source, meta.problems, askers(meta))
  rescue
    e ->
      Logger.error(
        "[AnalysisReport] delivering #{meta.source} findings failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end

  # The requester, then any agent waiting on a run it did not start.
  defp askers(meta), do: [meta.requester | Map.get(meta, :waiters, [])]

  @doc """
  Tell every internal agent in this run's working copy what landed.

  `requester_id` is the agent that asked for the run, or a list of every agent
  waiting on it; each is answered whatever the run found.

  Answers `:ok` regardless. This runs at the end of `Reconciler.reconcile/4`,
  where the run has already been recorded — a delivery that fails must not make
  a completed run look incomplete.
  """
  @spec deliver(Scope.t(), atom() | String.t(), [struct()], String.t() | [String.t()] | nil) ::
          :ok
  def deliver(scope, source, problems, requester_id \\ nil)

  def deliver(%Scope{active_working_copy_id: copy_id} = scope, source, problems, requester_id)
      when is_binary(copy_id) do
    blocking = Blocking.blockable(scope, problems)
    advisory = length(problems) - length(blocking)
    findings = digest(source, length(blocking), advisory)
    askers = agent_uuids(requester_id)

    scope
    |> agents_to_tell(copy_id, askers)
    |> Enum.each(&tell_one(scope, &1, {findings, advisory}, source, askers))
  end

  def deliver(_scope, _source, _problems, _requester_id), do: :ok

  @doc """
  Tell the agent that requested a run that it failed.

  Only the requester: a failed run has no findings for anyone else, and one
  nobody requested stays silent. A requester that is not an agent row (a
  Claude Code subagent id) is told nothing here.
  """
  @spec deliver_failure(
          Scope.t(),
          atom() | String.t(),
          String.t(),
          String.t() | [String.t()] | nil
        ) :: :ok
  def deliver_failure(%Scope{active_working_copy_id: copy_id} = scope, source, reason, requester)
      when is_binary(copy_id) do
    case agent_uuids(requester) do
      [] ->
        :ok

      agent_ids ->
        scope
        |> requesting_agents(copy_id, agent_ids)
        |> Enum.each(&tell(scope, &1, :own_reply, failed(source, reason)))
    end
  end

  def deliver_failure(_scope, _source, _reason, _requester), do: :ok

  defp failed(source, reason) do
    """
    Your #{source} run failed without a result: #{reason}

    This is the answer to the run you started — it is not coming. Nothing it
    was meant to measure has been measured, so start the #{source} run again
    rather than waiting on this one.
    """
  end

  # `requested_by["agent_id"]` is an agent UUID or a Claude Code subagent id
  # (short hex, never an `agents` row). Only a UUID is queried: the other raised
  # as `:binary_id` and failed a completed reconcile.
  defp agent_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp agent_uuid(_id), do: nil

  defp agent_uuids(ids) do
    ids |> List.wrap() |> Enum.map(&agent_uuid/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # The asker is answered whatever the run found; everyone else keeps the
  # silence a clean tree earns them, and hears findings only if `Wake` says
  # its role does (`RoleProfile.wake` naming `:findings`).
  # Findings are a problems offer; a clean answer to the asker is not.
  defp tell_one(scope, %{id: id} = agent, {findings, advisory}, source, askers) do
    offer = findings && {:problems, {"analysis", to_string(source)}}

    cond do
      id in askers -> tell(scope, agent, :own_reply, findings || clean(source, advisory), offer)
      findings -> tell(scope, agent, :findings, findings, offer)
      true -> :ok
    end
  end

  defp clean(source, advisory) do
    """
    Your #{source} run finished: no blocking problems in this working copy#{advisory_note(advisory)}.

    This is the answer to the run you started, not a nudge — nothing here needs
    fixing. If a task was waiting on it, dispose of that task now rather than
    waiting further.
    """
  end

  # Everyone who asked (any engine -- a terminal agent has no other way to
  # hear that a run it is explicitly waiting on has landed, issue cdf54b03),
  # plus every Alloy agent for the unasked `:findings` broadcast. Not every
  # Claude Code session for that broadcast: it already gets a clean run's
  # silence or a dirty one's findings through its own Stop hook on its next
  # turn, and would be told twice.
  defp agents_to_tell(%Scope{active_project_id: project_id}, copy_id, askers) do
    Agent
    |> where([a], a.working_copy_id == ^copy_id and a.project_id == ^project_id)
    |> where([a], a.engine == :alloy or a.id in ^askers)
    |> Repo.all()
  end

  defp requesting_agents(%Scope{active_project_id: project_id}, copy_id, agent_ids) do
    Agent
    |> where(
      [a],
      a.id in ^agent_ids and a.working_copy_id == ^copy_id and a.project_id == ^project_id
    )
    |> Repo.all()
  end

  # Admission is synchronous and durable; only transport runs off this process,
  # because a failure may be announced from inside the harness channel and
  # dispatch calls back into it (`:would_deadlock`).
  defp tell(_scope, %Agent{} = agent, event, message, offer \\ nil) do
    CodeMySpec.Agents.send_to_agent(agent.id, message, event, offer: offer, async: true)

    :ok
  end

  # What landed, by source, and what to do about it; `nil` when nothing blocks.
  # Counted by `Blocking.blockable/2`, the gate's own definition.
  defp digest(_source, 0, _advisory), do: nil

  defp digest(source, count, advisory) do
    """
    Your #{source} run finished: #{count} blocking #{noun(count)}#{advisory_note(advisory)} in this working copy.

    Call `list_problems` for the detail. If they are yours, fix them and run
    the analyzers again; if the run says something you have already fixed,
    it measured the tree before your edit and the next one will disagree
    with it.
    """
  end

  defp advisory_note(0), do: ""
  defp advisory_note(count), do: " (#{count} advisory)"

  defp noun(1), do: "problem"
  defp noun(_), do: "problems"
end
