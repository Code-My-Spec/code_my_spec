defmodule CodeMySpec.Agents.Offers do
  @moduledoc """
  Every nudge the harness sends an agent, as an offer with an observed outcome
  (b75b0198, step 1).

  Record only. Each nudge path calls `record/4` once, after recording its
  message, and the turn-end path calls `settle_turn/1` once. Nothing reads these
  rows to decide anything, so neither call may change what is sent or whether.

  ## Expectations, by kind

    * `:work` — `start_task` on the subject this turn; a task-scoped `tap_out`
      on it is `:declined` with its reason. A questions-only offer (main) wants
      `answer_notification`.
    * `:problems`, `:menu`, `:retry` — any tool call after delivery.
    * `:answer` — `check_answer`, or resuming the task the question blocked.
    * `:unblocked` — resuming a task the blocker held.
    * `:resume` — informational: `:n_a`.
    * `:check_in` — no fixed expectation: `:n_a`, noting the tools it called.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.OfferMessage
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo

  # Bump a kind's version when its prompt text changes, so claim rates can be
  # compared per template. Templates: `:work`, `:resume`, `:check_in` in `Work`
  # and `MainAgent.CheckInReport`; `:menu`, `:problems` in `StopDecision` and
  # `Validation.Menu`; `:retry` in `Agents`; `:answer` and `:unblocked` in
  # `Notifications` and `TaskOwner`.
  @template_versions %{
    work: "work/1",
    menu: "menu/1",
    problems: "problems/1",
    resume: "resume/1",
    retry: "retry/1",
    answer: "answer/1",
    unblocked: "unblocked/1",
    check_in: "check_in/1"
  }

  @type subject :: {String.t(), term()}

  @doc """
  Record an offer of `kind` on `subject`, linked to the message it was recorded
  as. `recorded` is what `Conversations.record_sent_to_agent/2` answered; with
  no message there, the offer stands unlinked.

  An open offer of the same kind and subject is superseded. Always `:ok`.
  """
  @spec record(term(), Agent.t(), Offer.kind(), subject()) :: :ok
  def record(recorded, %Agent{id: agent_id} = agent, kind, {type, key})
      when is_binary(agent_id) do
    key = subject_key(key)
    now = DateTime.utc_now()
    same = same_subject(agent_id, kind, type, key)
    attempt = attempt(same)

    # No transaction of its own: some callers may be inside one, and a
    # rollback here would take theirs with it.
    Repo.update_all(where(same, [o], o.status == :open),
      set: [status: :superseded, outcome_at: now, updated_at: now]
    )

    with {:ok, offer} <- insert_offer(agent, kind, type, key, attempt) do
      link(offer, recorded)
    end

    :ok
  end

  def record(_recorded, _agent, _kind, _subject), do: :ok

  @doc "This agent's offers, oldest first, with their message links."
  @spec list_for_agent(Ecto.UUID.t()) :: [Offer.t()]
  def list_for_agent(agent_id) do
    Offer
    |> where([o], o.agent_id == ^agent_id)
    |> order_by([o], asc: o.inserted_at, asc: o.id)
    |> preload(:messages)
    |> Repo.all()
  end

  @doc """
  Settle every open offer this agent holds from what its turn did: its tasks
  and the tool calls on its conversation since each offer was made. Called at
  turn end, before anything new is offered. Always `:ok`.
  """
  @spec settle_turn(Agent.t()) :: :ok
  def settle_turn(%Agent{id: agent_id} = agent) when is_binary(agent_id) do
    open =
      Offer
      |> where([o], o.agent_id == ^agent_id and o.status == :open)
      |> order_by([o], asc: o.inserted_at)
      |> Repo.all()

    settle(open, agent)
  end

  def settle_turn(_agent), do: :ok

  defp settle([], _agent), do: :ok

  defp settle([first | _] = open, agent) do
    now = DateTime.utc_now()
    calls = Conversations.tool_calls_since(agent.id, first.inserted_at)

    Enum.each(open, fn offer ->
      after_offer = Enum.filter(calls, &(DateTime.compare(&1.at, offer.inserted_at) != :lt))

      offer
      |> Offer.outcome_changeset(Map.put(outcome(offer, agent, after_offer), :outcome_at, now))
      |> Repo.update()
    end)
  end

  defp outcome(%Offer{kind: :resume}, _agent, _calls), do: %{status: :n_a}

  defp outcome(%Offer{kind: :check_in}, _agent, calls),
    do: %{status: :n_a, note: tools_note(calls)}

  defp outcome(%Offer{kind: kind}, _agent, calls) when kind in [:problems, :menu, :retry],
    do: claimed_if(calls != [])

  defp outcome(%Offer{kind: :work, subject_type: "questions"}, _agent, calls),
    do: claimed_if(called?(calls, "answer_notification"))

  defp outcome(%Offer{kind: :work} = offer, agent, _calls) do
    tasks = tasks_on(agent, offer.subject_key)

    case Enum.find(tasks, &tapped_out_since?(&1, offer.inserted_at)) do
      nil -> claimed_if(Enum.any?(tasks, &started_since?(&1, offer.inserted_at)))
      tapped -> %{status: :declined, reason: tapped.blocked_reason}
    end
  end

  defp outcome(%Offer{kind: :answer} = offer, agent, calls),
    do:
      claimed_if(
        called?(calls, "check_answer") or resumed_blocked_by?(agent, offer, offer.subject_key)
      )

  defp outcome(%Offer{kind: :unblocked} = offer, agent, _calls),
    do: claimed_if(resumed_blocked_by?(agent, offer, offer.subject_key))

  defp claimed_if(true), do: %{status: :claimed}
  defp claimed_if(false), do: %{status: :ignored}

  # Tools reached through `run_script` are named in its arguments.
  defp called?(calls, tool) do
    Enum.any?(calls, fn %{name: name, arguments: arguments} ->
      String.ends_with?(name, tool) or
        (String.ends_with?(name, "run_script") and String.contains?(inspect(arguments), tool))
    end)
  end

  defp tools_note([]), do: "no tool calls"

  defp tools_note(calls) do
    calls
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.join(", ")
    |> then(&("called: " <> &1))
    |> String.slice(0, 500)
  end

  defp tasks_on(%Agent{tasks: tasks}, key) when is_binary(key) do
    case String.split(key, ":", parts: 3) do
      [type, id, name] ->
        node = %{entity_type: type, entity_id: id, name: name}
        Enum.filter(tasks || [], &Work.task_on_node?(&1, node))

      _ ->
        []
    end
  end

  defp tasks_on(_agent, _key), do: []

  defp resumed_blocked_by?(%Agent{tasks: tasks}, offer, blocker_id) when is_binary(blocker_id) do
    Enum.any?(
      tasks || [],
      &(&1.blocker_id == blocker_id and started_since?(&1, offer.inserted_at))
    )
  end

  defp resumed_blocked_by?(_agent, _offer, _blocker_id), do: false

  defp started_since?(%{started_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp started_since?(_task, _since), do: false

  defp tapped_out_since?(%{blocker_type: :tap_out, blocked_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp tapped_out_since?(_task, _since), do: false

  defp same_subject(agent_id, kind, type, nil) do
    where(
      Offer,
      [o],
      o.agent_id == ^agent_id and o.kind == ^kind and o.subject_type == ^type and
        is_nil(o.subject_key)
    )
  end

  defp same_subject(agent_id, kind, type, key) do
    where(
      Offer,
      [o],
      o.agent_id == ^agent_id and o.kind == ^kind and o.subject_type == ^type and
        o.subject_key == ^key
    )
  end

  # How many times in a row this subject has been offered without a claim.
  defp attempt(same) do
    last_claimed =
      Repo.one(from o in same, where: o.status == :claimed, select: max(o.inserted_at))

    since =
      if last_claimed, do: where(same, [o], o.inserted_at > ^last_claimed), else: same

    Repo.aggregate(since, :count) + 1
  end

  defp insert_offer(agent, kind, type, key, attempt) do
    %{
      account_id: agent.account_id,
      project_id: agent.project_id,
      agent_id: agent.id,
      working_copy_id: agent.working_copy_id,
      kind: kind,
      subject_type: type,
      subject_key: key,
      attempt: attempt,
      status: :open,
      template_version: Map.fetch!(@template_versions, kind)
    }
    |> Offer.changeset()
    |> Repo.insert()
  end

  defp link(offer, {:ok, %Message{id: message_id}}) do
    %{offer_id: offer.id, message_id: message_id}
    |> OfferMessage.changeset()
    |> Repo.insert()
  end

  defp link(_offer, _not_recorded), do: {:ok, nil}

  defp subject_key(nil), do: nil
  defp subject_key(key) when is_binary(key), do: key
  defp subject_key(key), do: to_string(key)
end
