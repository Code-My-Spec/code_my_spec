defmodule CodeMySpec.Agents.Offers do
  @moduledoc """
  Every nudge the harness sends an agent, as an offer with an observed outcome
  (b75b0198, step 1).

  Record only. Each nudge path calls `record/4` once, after recording its
  message, and the turn-end path calls `settle_turn/1` once. Nothing reads these
  rows to decide anything, so neither call may change what is sent or whether.

  ## Expectations, by kind

    * `:work` — `start_task` on the subject this turn, resuming a held task
      included (criterion 1865); a task-scoped `tap_out` on it is `:declined`
      with its reason. A questions-only offer (main) wants a waiting question
      answered, escalated or put to the user (criterion 1866).
    * `:problems`, `:menu`, `:retry`, `:answer`, `:stalled` — any tool call
      after delivery. An answer's text is in the delivered message, so it wants
      no fetch. `:stalled` is main told a teammate stalled, on `agent:<id>`.
    * `:unblocked` — `start_task` on the released task, on `task:<id>`
      (criterion 1862). Read from the call, not from where the task is at
      turn end: a task resumed and finished in one turn was resumed.
    * `:denial` — a declined tap-out: any `start_task` or
      `answer_notification` after it (criterion 1672).
    * `:resume` — informational: `:n_a`.
    * `:check_in` — no fixed expectation: `:n_a`, noting the tools it called.
    * `:instruction` — delivered and a subsequent turn observed: `:n_a`,
      noting delivered/seen. Operator compliance is not inferred. Repetition
      is reported to main once; it never suppresses a human's message.
    * `:team_free` — main re-assigning the named copy: `set_active_story` or
      `assign_issue_to_working_copy` naming it (criteria 1881, 1892).
  """

  import Ecto.Query
  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.OfferMessage
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  # Bump a kind's version when its prompt text changes, so claim rates can be
  # compared per template. Templates: `:work`, `:resume`, `:check_in` in `Work`
  # and `MainAgent.CheckInReport`; `:menu`, `:problems` in `StopDecision` and
  # `Validation.Menu`; `:retry` and the restart `:resume` notices in `Agents`;
  # `:answer`, `:unblocked` and `:denial` in `Notifications`, `TaskOwner` and `Work`; `:stalled` in
  # `MainAgent.Cadence.announce_stalls/2`.
  @template_versions %{
    work: "work/1",
    menu: "menu/1",
    problems: "problems/1",
    resume: "resume/1",
    retry: "retry/1",
    answer: "answer/1",
    unblocked: "unblocked/2",
    denial: "denial/1",
    check_in: "check_in/1",
    stalled: "stalled/1",
    team_free: "team_free/1",
    instruction: "instruction/1"
  }

  # What main can do with a waiting question it was offered.
  @question_moves ~w(answer_notification escalate_question ask_user_question)

  # What main can do to re-assign a team-free copy: a story, or an issue.
  @reassignment_tools ~w(set_active_story assign_issue_to_working_copy)

  # Three ignored offers of the same work and it is held back from that agent.
  @held_after 3

  @type subject :: {String.t(), term()}

  @doc """
  Record an offer of `kind` on `subject`, linked to the message it was recorded
  as. `recorded` is what `Conversations.record_sent_to_agent/2` answered; with
  no message there, the offer stands unlinked.

  An open offer of the same kind and subject is superseded. Answers the offer,
  or nil when none was written, for `undelivered/1`. A failed write is logged
  at warning and never raised: recording must not change what is sent (f5699eb9).
  """
  @spec record(term(), Agent.t(), Offer.kind(), subject()) :: Offer.t() | nil
  def record(recorded, %Agent{id: agent_id} = agent, kind, {type, key})
      when is_binary(agent_id) do
    key = subject_key(key)

    # One agent's offers are recorded one at a time. A released task is offered
    # by the release and by the graph change it causes, from two processes, and
    # unserialized both read "no open offer" and stayed open side by side.
    # A session lock rather than a transaction: some callers may be inside one,
    # and a rollback here would take theirs with it.
    case serialized(agent_id, fn -> supersede_and_insert(agent, kind, type, key) end) do
      {:ok, offer} ->
        link(offer, recorded)
        offer

      {:error, changeset} ->
        Logger.warning(
          "[Offers] offer not recorded: kind=#{inspect(kind)} subject=#{inspect({type, key})} " <>
            "agent=#{agent_id} errors=#{inspect(errors(changeset))}"
        )

        nil
    end
  end

  def record(_recorded, _agent, _kind, _subject), do: nil

  @doc """
  The same offer said again: link `recorded` to the open offer of this kind and
  subject if there is one, and record a new offer only if there is not.

  For a notice that repeats an offer already standing — a release told on the
  thread while the turn the release caused is in flight. Superseding would
  restamp the offer after the agent had already acted on it.
  """
  @spec record_or_link(term(), Agent.t(), Offer.kind(), subject()) :: Offer.t() | nil
  def record_or_link(recorded, %Agent{id: agent_id} = agent, kind, {type, key} = subject)
      when is_binary(agent_id) do
    standing =
      agent_id
      |> same_subject(kind, type, subject_key(key))
      |> where([o], o.status == :open)
      |> order_by([o], desc: o.inserted_at)
      |> limit(1)
      |> Repo.one()

    case standing do
      nil ->
        record(recorded, agent, kind, subject)

      offer ->
        link(offer, recorded)
        offer
    end
  end

  def record_or_link(recorded, agent, kind, subject), do: record(recorded, agent, kind, subject)

  defp supersede_and_insert(agent, kind, type, key) do
    now = DateTime.utc_now()
    same = same_subject(agent.id, kind, type, key)
    attempt = attempt(same)

    Repo.update_all(where(same, [o], o.status == :open),
      set: [status: :superseded, outcome_at: now, updated_at: now]
    )

    insert_offer(agent, kind, type, key, attempt)
  end

  defp serialized(agent_id, fun) do
    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock(hashtext($1))", ["offers:" <> agent_id])

      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock(hashtext($1))", ["offers:" <> agent_id])
      end
    end)
  end

  @doc """
  Mark an offer whose delivery failed or was held (criterion 1676). Only an
  open offer moves; `ignored` must mean the agent saw it. Always `:ok`.
  """
  @spec undelivered(Offer.t() | nil) :: :ok
  def undelivered(%Offer{id: id}) do
    now = DateTime.utc_now()

    Offer
    |> where([o], o.id == ^id and o.status == :open)
    |> Repo.update_all(set: [status: :undelivered, outcome_at: now, updated_at: now])

    :ok
  end

  def undelivered(_offer), do: :ok

  @default_limit 50

  @doc """
  This project's offers, newest first, with their agent and linked messages.

  Filters, all optional: `:agent_id`, `:kind`, `:status`, `:since` (a
  `DateTime`, on `inserted_at`), and `:limit` (default #{@default_limit}).
  """
  @spec list(Scope.t(), keyword()) :: [Offer.t()]
  def list(%Scope{} = scope, filters \\ []) do
    scope
    |> filtered(filters)
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> limit(^Keyword.get(filters, :limit, @default_limit))
    |> preload([:agent, messages: :message])
    |> Repo.all()
  end

  @doc "How many offers match `filters` (ignoring `:limit`), by `{kind, status}`."
  @spec count_by_kind_and_status(Scope.t(), keyword()) :: %{
          {Offer.kind(), Offer.status()} => pos_integer()
        }
  def count_by_kind_and_status(%Scope{} = scope, filters \\ []) do
    scope
    |> filtered(filters)
    |> group_by([o], [o.kind, o.status])
    |> select([o], {{o.kind, o.status}, count(o.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp filtered(scope, filters) do
    Enum.reduce(
      filters,
      where(
        Offer,
        [o],
        o.account_id == ^scope.active_account_id and o.project_id == ^scope.active_project_id
      ),
      &filter/2
    )
  end

  defp filter({:agent_id, id}, query) when is_binary(id), do: where(query, [o], o.agent_id == ^id)

  defp filter({:kind, kind}, query) when is_atom(kind) and not is_nil(kind),
    do: where(query, [o], o.kind == ^kind)

  defp filter({:status, status}, query) when is_atom(status) and not is_nil(status),
    do: where(query, [o], o.status == ^status)

  defp filter({:since, %DateTime{} = at}, query), do: where(query, [o], o.inserted_at >= ^at)
  defp filter(_other, query), do: query

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
      |> preload(messages: :message)
      |> Repo.all()
      |> Enum.flat_map(&delivered_offer/1)
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    settle(open, agent)
  end

  def settle_turn(_agent), do: :ok

  @doc "A turn beginning acknowledges delivered operator instructions, without judging compliance."
  def observe_instruction_turn(%Agent{id: agent_id} = agent) do
    Offer
    |> where([o], o.agent_id == ^agent_id and o.kind == :instruction and o.status == :open)
    |> preload(messages: :message)
    |> Repo.all()
    |> Enum.flat_map(&delivered_offer/1)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> settle(agent)
  end

  # Queuing is not delivery. Calls in the preceding turn cannot claim a
  # message the agent has not picked up, nor can that turn ignore it.
  defp delivered_offer(%Offer{messages: []} = offer), do: [offer]

  defp delivered_offer(%Offer{} = offer) do
    messages = Enum.map(offer.messages, & &1.message)

    delivered =
      Enum.filter(messages, &(&1.delivery in [nil, :delivered]))

    delivery_window(offer, delivered, messages)
  end

  defp delivery_window(offer, [], messages) do
    if Enum.any?(messages, &(&1.delivery == :pending)) do
      []
    else
      undelivered(offer)
      []
    end
  end

  defp delivery_window(offer, delivered, _messages) do
    since =
      delivered
      |> Enum.map(&delivery_time/1)
      |> Enum.min(DateTime)

    # Only the observation window changes; the persisted creation time stays.
    [%{offer | inserted_at: Enum.max([offer.inserted_at, since], DateTime)}]
  end

  defp delivery_time(%Message{delivery: :delivered, updated_at: at}), do: at
  defp delivery_time(%Message{inserted_at: at}), do: at

  @doc """
  Where each piece of work stands with this agent, for the escalation ladder
  (criteria 1739–1741): `%{subject_key => %{ignored: n, held?: boolean}}`,
  for requirement work offers only. `ignored` counts ignored offers since the
  last claim; `held?` is three of them, or a decline since.
  """
  @spec standing(Ecto.UUID.t()) :: %{
          String.t() => %{ignored: non_neg_integer(), held?: boolean()}
        }
  def standing(agent_id) when is_binary(agent_id) do
    Offer
    |> where(
      [o],
      o.agent_id == ^agent_id and o.kind == :work and o.subject_type == "requirement" and
        o.status in [:claimed, :declined, :ignored]
    )
    |> order_by([o], desc: o.inserted_at)
    |> select([o], {o.subject_key, o.status})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, statuses} -> {key, streak(statuses)} end)
  end

  def standing(_agent_id), do: %{}

  # Newest first, up to the last claim.
  defp streak(statuses) do
    recent = Enum.take_while(statuses, &(&1 != :claimed))
    ignored = Enum.count(recent, &(&1 == :ignored))
    %{ignored: ignored, held?: ignored >= @held_after or :declined in recent}
  end

  @doc "Record one escalation for a repeated operator instruction; never withhold delivery."
  def take_instruction_attention(%Offer{kind: :instruction} = offer) do
    serialized(offer.agent_id, fn ->
      same = same_subject(offer.agent_id, :instruction, offer.subject_type, offer.subject_key)
      repeated? = Repo.aggregate(same, :count) > 1
      reported? = Repo.exists?(where(same, [o], o.next_step == "told_main"))

      case {repeated?, reported?} do
        {true, false} ->
          Repo.update_all(where(Offer, [o], o.id == ^offer.id),
            set: [next_step: "told_main", updated_at: DateTime.utc_now()]
          )

          true

        _ ->
          false
      end
    end)
  end

  def take_instruction_attention(_offer), do: false

  @doc "How many ignored offers hold work back from an agent (criterion 1741)."
  def held_after, do: @held_after

  @doc """
  Decline an open offer with a reason (criterion 1738): `offer_id`, or the
  agent's newest open offer when nil. Answers the declined offer.
  """
  @spec reject(Ecto.UUID.t(), Ecto.UUID.t() | nil, String.t()) ::
          {:ok, Offer.t()} | {:error, :not_found}
  def reject(agent_id, offer_id, reason) when is_binary(agent_id) and is_binary(reason) do
    case open_offer(agent_id, offer_id) do
      nil ->
        {:error, :not_found}

      offer ->
        now = DateTime.utc_now()

        offer
        |> Ecto.Changeset.change(
          status: :declined,
          reason: reason,
          next_step: "told_main",
          outcome_at: now
        )
        |> Repo.update()
    end
  end

  @doc """
  Close this agent's open work offers on `key` as declined: the work was found
  already done when it tried to take it (67e6b5cb). The system knows the offer
  is stale, so it does not wait for the agent to say so. Always `:ok`.
  """
  @spec close_stale(Ecto.UUID.t(), String.t()) :: :ok
  def close_stale(agent_id, key) when is_binary(agent_id) and is_binary(key) do
    now = DateTime.utc_now()

    Offer
    |> where(
      [o],
      o.agent_id == ^agent_id and o.kind == :work and o.subject_type == "requirement" and
        o.subject_key == ^key and o.status == :open
    )
    |> Repo.update_all(
      set: [status: :declined, reason: "already satisfied", outcome_at: now, updated_at: now]
    )

    :ok
  end

  defp open_offer(agent_id, nil) do
    Offer
    |> where([o], o.agent_id == ^agent_id and o.status == :open)
    |> order_by([o], desc: o.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp open_offer(agent_id, offer_id) do
    case Ecto.UUID.cast(offer_id) do
      {:ok, id} ->
        Repo.one(where(Offer, [o], o.id == ^id and o.agent_id == ^agent_id and o.status == :open))

      :error ->
        nil
    end
  end

  @doc "This agent's offers settled at or after `at`."
  @spec settled_since(Ecto.UUID.t(), DateTime.t()) :: [Offer.t()]
  def settled_since(agent_id, %DateTime{} = at) do
    Offer
    |> where([o], o.agent_id == ^agent_id and o.outcome_at >= ^at)
    |> Repo.all()
  end

  defp settle([], _agent), do: :ok

  defp settle([first | _] = open, agent) do
    now = DateTime.utc_now()
    calls = Conversations.tool_calls_since(agent.id, first.inserted_at)

    Enum.each(open, fn offer ->
      after_offer = Enum.filter(calls, &(DateTime.compare(&1.at, offer.inserted_at) != :lt))

      settled =
        offer
        |> outcome(agent, after_offer)
        |> Map.merge(%{outcome_at: now, updated_at: now})
        |> next_step(offer)

      # Still open when written: a delivery failure marked since the read stands.
      Offer
      |> where([o], o.id == ^offer.id and o.status == :open)
      |> Repo.update_all(set: Map.to_list(settled))
    end)
  end

  # The ladder's next rung, written on the offer it follows (criteria
  # 1739–1741). Work offers only; nothing else escalates (criterion 1742).
  defp next_step(
         %{status: :ignored} = settled,
         %Offer{kind: :work, subject_type: "requirement"} = offer
       ) do
    step =
      case standing(offer.agent_id)[offer.subject_key] do
        %{ignored: n} when n + 1 >= @held_after -> "held_back"
        %{ignored: 1} -> "alternatives"
        _ -> "detail"
      end

    Map.put(settled, :next_step, step)
  end

  defp next_step(settled, _offer), do: settled

  defp outcome(%Offer{kind: :resume}, _agent, _calls), do: %{status: :n_a}

  defp outcome(%Offer{kind: :check_in}, _agent, calls),
    do: %{status: :n_a, note: tools_note(calls)}

  defp outcome(%Offer{kind: :instruction}, _agent, _calls),
    do: %{status: :n_a, note: "delivered/seen; instruction compliance is not inferred"}

  defp outcome(%Offer{kind: kind}, _agent, calls)
       when kind in [:problems, :menu, :retry, :answer, :stalled],
       do: claimed_if(calls != [])

  defp outcome(%Offer{kind: :work, subject_type: "questions"}, _agent, calls),
    do: claimed_if(Enum.any?(@question_moves, &called?(calls, &1)))

  defp outcome(%Offer{kind: :work} = offer, agent, calls) do
    tasks = tasks_on(agent, offer.subject_key)

    cond do
      tapped = Enum.find(tasks, &tapped_out_since?(&1, offer.inserted_at)) ->
        %{status: :declined, reason: tapped.blocked_reason}

      # Claimed and cancelled is declined, or the claim would reset the ladder
      # and the agent could take and drop the same work forever (7169d3cf).
      Enum.any?(tasks, &cancelled_since?(&1, offer.inserted_at)) ->
        %{status: :declined, reason: "claimed and cancelled"}

      true ->
        claimed_if(
          Enum.any?(tasks, &(started_since?(&1, offer.inserted_at) or start_called?(calls, &1)))
        )
    end
  end

  # The call, or the task's own state: active now, or finished since the offer.
  # Either says it was resumed; neither depends on where it stands otherwise.
  defp outcome(%Offer{kind: :unblocked, subject_type: "task"} = offer, agent, calls) do
    case Enum.find(agent.tasks || [], &(&1.id == offer.subject_key)) do
      nil -> claimed_if(false)
      task -> claimed_if(start_called?(calls, task) or resumed_since?(task, offer.inserted_at))
    end
  end

  # Offers recorded on the blocker before criterion 1862.
  defp outcome(%Offer{kind: :unblocked} = offer, agent, _calls),
    do: claimed_if(resumed?(agent, offer.subject_key))

  defp outcome(%Offer{kind: :denial}, _agent, calls),
    do: claimed_if(called?(calls, "start_task") or called?(calls, "answer_notification"))

  # Claimed when main re-assigned this freed copy: a story with
  # `set_active_story` or an issue with `assign_issue_to_working_copy`,
  # both naming the copy with `working_copy_id`.
  defp outcome(%Offer{kind: :team_free, subject_key: copy_id}, _agent, calls),
    do: claimed_if(assigned_to_copy?(calls, copy_id))

  defp claimed_if(true), do: %{status: :claimed}
  defp claimed_if(false), do: %{status: :ignored}

  # A `start_task` naming this task's requirement on the same kind of entity,
  # directly or through `run_script`. Resuming keeps `started_at`, so the call
  # is the evidence (criteria 1862, 1865). Not the entity's id: an agent names
  # a story by number, the task holds its id, and one agent does not hold two
  # tasks on the same requirement.
  defp start_called?(calls, task) do
    Enum.any?(calls, fn %{name: name, arguments: arguments} ->
      cond do
        String.ends_with?(name, "start_task") ->
          arguments["requirement_name"] == task.requirement_name and
            entity_type_matches?(arguments["entity_type"], task)

        String.ends_with?(name, "run_script") ->
          script = inspect(arguments)

          String.contains?(script, "start_task") and
            String.contains?(script, task.requirement_name)

        true ->
          false
      end
    end)
  end

  defp entity_type_matches?(nil, _task), do: true
  defp entity_type_matches?("story", task), do: not is_nil(task.story_id)
  defp entity_type_matches?("component", task), do: not is_nil(task.component_id)

  defp entity_type_matches?("project", task),
    do: is_nil(task.story_id) and is_nil(task.component_id)

  defp entity_type_matches?(_type, _task), do: false

  defp assigned_to_copy?(calls, copy_id) do
    Enum.any?(calls, fn %{name: name, arguments: arguments} ->
      cond do
        Enum.any?(@reassignment_tools, &String.ends_with?(name, &1)) ->
          arguments["working_copy_id"] == copy_id

        String.ends_with?(name, "run_script") ->
          script = inspect(arguments)

          Enum.any?(@reassignment_tools, &String.contains?(script, &1)) and
            String.contains?(script, to_string(copy_id))

        true ->
          false
      end
    end)
  end

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

  # Resuming clears the task's blocker and keeps its `started_at`, so a resumed
  # task is one no longer blocked by this blocker, with the agent back on a task.
  defp resumed?(%Agent{} = agent, blocker_id),
    do: not blocked_by?(agent, blocker_id) and Agent.active_task(agent) != nil

  defp blocked_by?(%Agent{tasks: tasks}, blocker_id),
    do: Enum.any?(tasks || [], &(&1.status == :blocked and &1.blocker_id == blocker_id))

  defp started_since?(%{started_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp started_since?(_task, _since), do: false

  defp tapped_out_since?(%{blocker_type: :tap_out, blocked_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp tapped_out_since?(_task, _since), do: false

  defp resumed_since?(%{status: :active}, _since), do: true

  defp resumed_since?(%{status: :completed, completed_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp resumed_since?(_task, _since), do: false

  defp cancelled_since?(%{status: :cancelled, completed_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp cancelled_since?(_task, _since), do: false

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
  # An undelivered offer was never made, so it does not count.
  defp attempt(same) do
    last_claimed =
      Repo.one(from o in same, where: o.status == :claimed, select: max(o.inserted_at))

    since =
      if last_claimed, do: where(same, [o], o.inserted_at > ^last_claimed), else: same

    since |> where([o], o.status != :undelivered) |> Repo.aggregate(:count) |> Kernel.+(1)
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
    |> tap(fn
      {:ok, _link} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[Offers] offer #{offer.id} not linked to message #{message_id}: " <>
            "errors=#{inspect(errors(changeset))}"
        )
    end)
  end

  defp link(_offer, _not_recorded), do: {:ok, nil}

  defp errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

  defp subject_key(nil), do: nil
  defp subject_key(key) when is_binary(key), do: key
  defp subject_key(key), do: to_string(key)
end
