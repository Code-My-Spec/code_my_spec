defmodule CodeMySpec.Agents.Offers do
  @moduledoc """
  Every nudge the harness sends an agent, as an offer with an observed outcome.

  Each nudge path calls `record/4` once, after recording its message, and the
  turn-end path calls `settle_turn/1` once; neither may change what is sent or
  whether.

  ## A turn on its way

  A nudge that wakes an agent with a turn of its own goes through
  `dispatch/3` instead, under the agent's row lock, and the offer is stamped
  `turn_requested_at`. Open, with no turn running and inside the TTL, that offer
  is the one thing that says a turn is on its way (`in_flight?/1`): `Work`
  hands out no second turn while it stands, and main is not told the agent
  stalled.

  ## Expectations, by kind

    * `:work` — `start_task` on the subject this turn, resuming a held task
      included; a task-scoped `tap_out` on it, or a claim then cancel, is
      `:declined`. A questions-only offer (main) wants a waiting question
      answered, escalated or put to the user.
    * `:problems`, `:menu`, `:retry`, `:answer`, `:stalled` — any tool call
      after delivery. An answer's text is in the delivered message, so it wants
      no fetch. `:stalled` is main told a teammate stalled, on `agent:<id>`.
    * `:unblocked` — `start_task` on the released task, on `task:<id>`.
      Read from the call, not from where the task is at
      turn end: a task resumed and finished in one turn was resumed.
    * `:denial` — a declined tap-out: any `start_task` or
      `answer_notification` after it.
    * `:resume` — informational: `:n_a`.
    * `:check_in` — no fixed expectation: `:n_a`, noting the tools it called.
    * `:instruction` — delivered and a subsequent turn observed: `:n_a`,
      noting delivered/seen. Operator compliance is not inferred. Repetition
      is reported to main once; it never suppresses a human's message.
    * `:team_free` — main re-assigning the named copy: `set_active_story` or
      `assign_issue_to_working_copy` naming it.
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
  # and `Agents.Main.CheckInReport`; `:menu`, `:problems` in `StopDecision` and
  # `Agents.Menu`; `:retry` and the restart `:resume` notices in `Agents`;
  # `:answer`, `:unblocked` and `:denial` in `Notifications`, `TaskOwner` and `Work`; `:stalled` in
  # `Agents.Main.Cadence.announce_stalls/2`.
  @template_versions %{
    work: "work/1",
    menu: "menu/1",
    problems: "problems/1",
    resume: "resume/1",
    retry: "retry/1",
    answer: "answer/1",
    unblocked: "unblocked/3",
    denial: "denial/2",
    check_in: "check_in/1",
    stalled: "stalled/2",
    team_free: "team_free/1",
    instruction: "instruction/1"
  }

  # What main can do with a waiting question it was offered.
  @question_moves ~w(answer_notification escalate_question ask_user_question)

  # What main can do to re-assign a team-free copy: a story, or an issue.
  @reassignment_tools ~w(set_active_story assign_issue_to_working_copy)

  # The escalation ladder for every kind of offer that asks an agent to act, as
  # data. Keyed by `{kind, subject_type}`; after n ignored
  # offers the next rung is `Enum.at(ladder, n)`, and `:held_back` -- always
  # last -- is the rung that stops the offer reaching that agent at all.
  #
  # One map rather than a rule per kind, so a kind's own length is its
  # threshold: requirement work takes three ignored offers to be held back, a
  # released task two, a declined tap-out notice one. A kind not in this map
  # never escalates (resume, check-in, instruction).
  @ladders %{
    {:work, "requirement"} => [:detail, :alternatives, :held_back],
    {:work, "questions"} => [:held_back],
    {:unblocked, "task"} => [:remind, :held_back],
    {:denial, "tap_out"} => [:held_back],
    # Keyed on the blocking set's own hash (`problem_key/1`), never on a task
    # or requirement id, so it cannot collide with another kind's subject_key
    # in `standing/1`'s per-key grouping (criterion 2168).
    {:problems, "problem_set"} => [:detail],
    {:retry, "failed_turn"} => [:detail]
  }

  @type subject :: {String.t(), term()}

  @doc """
  Record an offer of `kind` on `subject`, linked to the message it was recorded
  as. `recorded` is what `Conversations.record_sent_to_agent/2` answered; with
  no message there, the offer stands unlinked.

  An open offer of the same kind and subject is superseded. Answers the offer,
  or nil when none was written, for `undelivered/1`. A failed write is logged
  at warning and never raised: recording must not change what is sent.
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

  @doc "Whether this agent has an open offer of `kind` right now."
  @spec open_of_kind?(String.t(), Offer.kind()) :: boolean()
  def open_of_kind?(agent_id, kind) when is_binary(agent_id) and is_atom(kind) do
    Offer
    |> where([o], o.agent_id == ^agent_id and o.kind == ^kind and o.status == :open)
    |> Repo.exists?()
  end

  def open_of_kind?(_agent_id, _kind), do: false

  @doc """
  This agent's current open work offer, if it holds one -- regardless of
  subject. `Agents.Work.ensure_work_offer/2` backs a pull read
  (`get_next_requirement`) with this same single offer rather than
  recording a second one: one open offer is the agent's status
  (criterion 2161).
  """
  @spec current_work_offer(String.t()) :: Offer.t() | nil
  def current_work_offer(agent_id) when is_binary(agent_id) do
    Offer
    |> where([o], o.agent_id == ^agent_id and o.kind == :work and o.status == :open)
    |> order_by([o], desc: o.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def current_work_offer(_agent_id), do: nil

  @doc """
  Record a decline directly, with no open offer ever having existed for it:
  `reject_offer` called with no open offer and no id, declining whatever a
  pull (`get_next_requirement`) most recently showed (issue e6f18e57,
  product's ruling on 7371fb26). Written declined outright, same shape as
  any other decline, so it is held back exactly as `reject/3`'s own are.
  """
  @spec record_declined(Agent.t(), Offer.kind(), subject(), String.t()) :: Offer.t() | nil
  def record_declined(%Agent{id: agent_id} = agent, kind, {type, key}, reason)
      when is_binary(agent_id) and is_binary(reason) do
    key = subject_key(key)
    now = DateTime.utc_now()

    serialized(agent_id, fn ->
      attempt = agent_id |> same_subject(kind, type, key) |> attempt()

      %{
        account_id: agent.account_id,
        project_id: agent.project_id,
        agent_id: agent.id,
        working_copy_id: agent.working_copy_id,
        kind: kind,
        subject_type: type,
        subject_key: key,
        attempt: attempt,
        status: :declined,
        reason: reason,
        next_step: declined_step(%{kind: kind, subject_type: type}),
        outcome_at: now,
        template_version: Map.fetch!(@template_versions, kind)
      }
      |> Offer.changeset()
      |> Repo.insert()
    end)
    |> case do
      {:ok, offer} -> offer
      {:error, _changeset} -> nil
    end
  end

  def record_declined(_agent, _kind, _subject, _reason), do: nil

  @doc """
  Every open offer on this agent is superseded, not just one of a given kind
  and subject -- a restart discards the in-flight turn those offers were
  queued for (`turn_started_at: nil`), so none of them can still be claimed
  or ignored by it. Always `:ok`.
  """
  @spec supersede_queued(String.t()) :: :ok
  def supersede_queued(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now()

    Offer
    |> where([o], o.agent_id == ^agent_id and o.status == :open)
    |> Repo.update_all(set: [status: :superseded, outcome_at: now, updated_at: now])

    :ok
  end

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

  defp supersede_and_insert(agent, kind, type, key, turn_requested_at \\ nil) do
    now = DateTime.utc_now()
    same = same_subject(agent.id, kind, type, key)
    attempt = attempt(same)

    Repo.update_all(where(same, [o], o.status == :open),
      set: [status: :superseded, outcome_at: now, updated_at: now]
    )

    insert_offer(agent, kind, type, key, attempt, turn_requested_at)
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

  # A turn handed to a harness reports started within seconds. It has to lapse
  # because what closes it needs a live process: a harness that dies after
  # accepting the turn leaves the offer open, and an open turn request blocks
  # every other wake.
  @turn_request_ttl_seconds 300

  @never_started "never started"

  @doc """
  Record an offer handed to the agent's harness as a turn of its own:
  `record/4`'s offer, stamped `turn_requested_at`.

  `Work` calls this under the agent's row lock, after deciding the agent is
  runnable, so two events racing to wake one agent hand out one turn. The
  prompt is linked afterwards with `link_prompt/2`. Unlike `record/4`, a failed
  write is returned, not logged: here it means no turn was handed.
  """
  @spec dispatch(Agent.t(), Offer.kind(), subject()) :: {:ok, Offer.t()} | {:error, term()}
  def dispatch(%Agent{id: agent_id} = agent, kind, {type, key}) when is_binary(agent_id) do
    key = subject_key(key)
    now = DateTime.utc_now()

    serialized(agent_id, fn ->
      lapse(agent_id, now)
      supersede_and_insert(agent, kind, type, key, now)
    end)
  end

  # A turn request past the TTL never started. Superseded, as any offer made
  # again is, and noted, because that note is what tells the
  # next request apart from a first offer: without it every re-offer to a
  # harness that swallows turns read as a fresh hand-over, and the stall was
  # never reported.
  defp lapse(agent_id, now) do
    agent_id
    |> turn_requests()
    |> where([o], o.turn_requested_at <= ^cutoff())
    |> Repo.update_all(
      set: [status: :superseded, note: @never_started, outcome_at: now, updated_at: now]
    )
  end

  @doc "Link `offer` to the message its prompt was recorded as. Answers the offer."
  @spec link_prompt(Offer.t() | nil, term()) :: Offer.t() | nil
  def link_prompt(%Offer{} = offer, recorded) do
    link(offer, recorded)
    offer
  end

  def link_prompt(nil, _recorded), do: nil

  @doc "Whether a turn has been handed to this agent's harness and is still on its way."
  @spec in_flight?(String.t()) :: boolean()
  def in_flight?(agent_id) when is_binary(agent_id) do
    agent_id |> turn_requests() |> where([o], o.turn_requested_at > ^cutoff()) |> Repo.exists?()
  end

  def in_flight?(_agent_id), do: false

  @doc """
  The newest turn handed to this agent since its last turn that never started
  there — open past the TTL, lapsed, or undelivered — or nil. A stall with its reason:
  what was offered, and when. A turn still inside the TTL is not one; a turn
  the agent took and finished since is the end of it.
  """
  @spec unstarted_turn(String.t()) :: Offer.t() | nil
  def unstarted_turn(agent_id) when is_binary(agent_id) do
    since = last_turn_settled_at(agent_id)

    from(o in Offer,
      where:
        o.agent_id == ^agent_id and not is_nil(o.turn_requested_at) and
          (o.status == :undelivered or o.note == @never_started or
             (o.status == :open and o.turn_requested_at <= ^cutoff())),
      order_by: [desc: o.turn_requested_at],
      limit: 1
    )
    |> after_turn(since)
    |> Repo.one()
  end

  def unstarted_turn(_agent_id), do: nil

  @settled_by_a_turn [:claimed, :ignored, :declined, :n_a]

  defp last_turn_settled_at(agent_id) do
    from(o in Offer,
      where:
        o.agent_id == ^agent_id and not is_nil(o.turn_requested_at) and
          o.status in ^@settled_by_a_turn,
      select: max(o.outcome_at)
    )
    |> Repo.one()
  end

  defp after_turn(query, nil), do: query
  defp after_turn(query, at), do: where(query, [o], o.turn_requested_at > ^at)

  @doc """
  Close a turn request decided against before it went out: the agent moved
  between the read that chose the offer and the lock that took it. Only an open
  offer moves. Always `:ok`.
  """
  @spec withdraw(Offer.t() | nil) :: :ok
  def withdraw(%Offer{id: id}) do
    now = DateTime.utc_now()

    Offer
    |> where([o], o.id == ^id and o.status == :open)
    |> Repo.update_all(set: [status: :superseded, outcome_at: now, updated_at: now])

    :ok
  end

  def withdraw(_offer), do: :ok

  @doc """
  Close every turn handed to this agent's harness: the process it went to is
  gone (a harness restart, a stop, a reap). A turn that never started there was
  never delivered, so its offer is `:undelivered`; one that started was cut, and
  its offer is `:superseded`. `started?` is whether a turn was running. Always
  `:ok`.
  """
  @spec abandon_turns(String.t(), boolean()) :: :ok
  def abandon_turns(agent_id, started? \\ false)

  def abandon_turns(agent_id, started?) when is_binary(agent_id) do
    now = DateTime.utc_now()
    status = if started?, do: :superseded, else: :undelivered

    agent_id
    |> turn_requests()
    |> Repo.update_all(set: [status: status, outcome_at: now, updated_at: now])

    :ok
  end

  def abandon_turns(_agent_id, _started?), do: :ok

  defp turn_requests(agent_id) do
    where(
      Offer,
      [o],
      o.agent_id == ^agent_id and o.status == :open and not is_nil(o.turn_requested_at)
    )
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -@turn_request_ttl_seconds, :second)

  @doc """
  Mark an offer whose delivery failed or was held. Only an
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

  @doc """
  A transport's definite refusal settles one way, regardless of which path
  noticed it: the conversation message `:failed`, and any still-open offer
  linked to it `:undelivered`. Shared by `Agents.record_dispatch_result/3`
  (no `Mailbox.Entry` existed yet) and `Mailbox.reconcile_dispatch/4` (one
  did, and is moved off `:claimed` separately) -- a missing acknowledgement
  is not this; only a reason the transport itself reports as final is.
  """
  @spec fail_dispatch(Message.t()) :: :ok
  def fail_dispatch(%Message{} = message) do
    {:ok, _} = Conversations.set_delivery(message, :failed)
    undelivered_by_message(message.id)
  end

  # undelivered/1 by way of the message: fail_dispatch/1's two callers have
  # a message id in hand, not the Offer struct itself.
  defp undelivered_by_message(message_id) do
    now = DateTime.utc_now()

    from(o in Offer,
      join: link in OfferMessage,
      on: link.offer_id == o.id,
      where: link.message_id == ^message_id and o.status == :open
    )
    |> Repo.update_all(set: [status: :undelivered, outcome_at: now, updated_at: now])

    :ok
  end

  @default_limit 50

  @doc """
  This project's offers, newest first, with their agent and linked messages.

  Filters, all optional: `:agent_id`, `:working_copy_id`, `:kind`, `:status`, `:since` (a
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

  defp filter({:working_copy_id, id}, query) when is_binary(id),
    do: where(query, [o], o.working_copy_id == ^id)

  defp filter({:kind, kind}, query) when is_atom(kind) and not is_nil(kind),
    do: where(query, [o], o.kind == ^kind)

  defp filter({:status, status}, query) when is_atom(status) and not is_nil(status),
    do: where(query, [o], o.status == ^status)

  defp filter({:since, %DateTime{} = at}, query), do: where(query, [o], o.inserted_at >= ^at)

  defp filter({:role, role}, query) when is_atom(role) and not is_nil(role) do
    query
    |> join(:inner, [o], a in assoc(o, :agent), as: :role_agent)
    |> where([role_agent: a], a.role == ^role)
  end

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
  Where each piece of work stands with this agent, for the escalation ladder:
  `%{subject_key => %{ignored: n, held?: boolean}}`,
  for requirement work offers and released-task offers (keyed by task id).
  `ignored` counts ignored offers since the last claim; `held?` is the kind's
  own ladder length, or a decline since.

  Only laddered kinds are read: the filter is in SQL, because an agent that has
  been offered the same thing hundreds of times has hundreds of rows and this
  runs on every offer decision. Which ladder a row belongs to is decided in
  Elixir, per row, so two kinds sharing a subject key do not borrow each
  other's length.
  """
  @spec standing(Ecto.UUID.t()) :: %{
          String.t() => %{ignored: non_neg_integer(), held?: boolean()}
        }
  def standing(agent_id) when is_binary(agent_id) do
    kinds = Map.keys(@ladders) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    types = Map.keys(@ladders) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    Offer
    |> where(
      [o],
      o.agent_id == ^agent_id and
        o.kind in ^kinds and o.subject_type in ^types and
        o.status in [:claimed, :declined, :ignored, :open, :cancelled]
    )
    |> order_by([o], desc: o.inserted_at)
    |> select(
      [o],
      {o.subject_key, o.kind, o.subject_type, o.status, o.attempt, o.outcome_at, o.next_step}
    )
    |> Repo.all()
    |> Enum.filter(&laddered?/1)
    |> Enum.group_by(
      &elem(&1, 0),
      &{elem(&1, 1), elem(&1, 2), elem(&1, 3), elem(&1, 4), elem(&1, 5), elem(&1, 6)}
    )
    |> Map.new(fn {key, settled} -> {key, streak(settled)} end)
  end

  def standing(_agent_id), do: %{}

  # The row's own kind decides whether it escalates: a kind not in `@ladders`
  # never does, and a row is only laddered when its whole key is.
  defp laddered?({_key, kind, type, _status, _attempt, _outcome_at, _next_step}),
    do: Map.has_key?(@ladders, {kind, type})

  # Newest first, up to the last claim. `ignored` is how many settled
  # ignored offers stand since then, for rung selection. Two different
  # things read this, per product's correction on 3e9a96e9 (which itself
  # corrects 1ef7cfe3) and main's correction on a01ffadb: `held?` is true for
  # EITHER an explicit decline OR an offer whose own attempt has reached the
  # last rung of its ladder -- both stop this agent from being pushed the
  # same work again (criterion 1741's throttle, which a literal reading of
  # 2169 would otherwise reopen). Exhaustion is read from that row's own
  # attempt number directly, not from counting settled `:ignored` rows --
  # the row at the last rung stays `:open` (outcome/3 leaves it unsettled,
  # criterion 2169), and `:open` is now included in the query above so that
  # row is still seen here. `declined?` is narrower, an explicit decline
  # alone: only that closes the offer and holds the work back from
  # `claimable_work` (get_next_requirement, start_task). An offer merely
  # exhausted by ignoring stays open, escalated to main once (criterion
  # 2169), and a pull still shows and can claim it -- `held?` must not gate
  # that. Each offer is read by the ladder for its own kind, so two kinds
  # can share a subject key.
  defp streak(settled) do
    # A claim-cancel is its own reset point, same as a claim (criterion 1815
    # restarts the attempt count there too) -- nothing before it should count
    # toward this subject's ignored/declined/exhausted streak.
    recent =
      Enum.take_while(settled, fn {_kind, _type, status, _attempt, _outcome_at, _next_step} ->
        status not in [:claimed, :cancelled]
      end)

    ignored =
      Enum.count(recent, fn {_kind, _type, status, _attempt, _outcome_at, _next_step} ->
        status == :ignored
      end)

    declined? =
      Enum.any?(recent, fn {_kind, _type, status, _attempt, _outcome_at, _next_step} ->
        status == :declined
      end)

    # An :ignored row has already been through a turn end. An :open row has
    # not, unless outcome_at is set -- which only happens once it has been
    # left open by outcome/3's own exhaustion branch (criterion 2169). A
    # freshly created, never-yet-settled :open row (outcome_at nil) is the
    # offer about to be delivered for the first time, even when its attempt
    # already equals the ladder's length -- the last rung is delivered once
    # before the agent not taking it counts as exhaustion (main's correction
    # on 21eb9860, which itself corrects a01ffadb's first cut).
    #
    # Criterion 2220: a third claim-cancel cycle escalates the same way, but
    # its own attempt is the push ladder's (reset by the claim, criterion
    # 1815) and can be far short of that ladder's length -- cycle_outcome/1
    # writes next_step "held_back" on the row directly rather than leaving it
    # to be derived from attempt, so this reads that instead of re-deriving.
    exhausted? =
      Enum.any?(recent, fn {kind, type, status, attempt, outcome_at, next_step} ->
        (status == :open and next_step == "held_back") or
          exhausted_rung?(kind, type, status, attempt, outcome_at)
      end)

    %{ignored: ignored, held?: declined? or exhausted?, declined?: declined?}
  end

  defp exhausted_rung?(kind, type, status, attempt, outcome_at) do
    settled_once? = status == :ignored or (status == :open and not is_nil(outcome_at))

    settled_once? and
      case ladder({kind, type}) do
        nil -> false
        steps -> attempt >= length(steps)
      end
  end

  @doc "Every escalation ladder, keyed by `{kind, subject_type}`."
  @spec ladders() :: %{{atom(), String.t()} => [atom()]}
  def ladders, do: @ladders

  @doc "The ladder for one offer kind, or nil when that kind never escalates."
  @spec ladder({atom(), String.t()}) :: [atom()] | nil
  def ladder(key), do: Map.get(@ladders, key)

  @doc """
  The agent's latest `kind` offer when its turn just left it ignored with
  `step` as its next rung, messages preloaded: the rung to send now. A kind
  sent again on an event of its own (`:retry`) has no other turn end to climb
  at. Otherwise nil.
  """
  @spec to_escalate(Ecto.UUID.t(), Offer.kind(), atom()) :: Offer.t() | nil
  def to_escalate(agent_id, kind, step) do
    from(o in Offer,
      where: o.agent_id == ^agent_id and o.kind == ^kind,
      order_by: [desc: o.inserted_at, desc: o.id],
      limit: 1,
      preload: [messages: :message]
    )
    |> Repo.one()
    |> escalation(to_string(step))
  end

  defp escalation(%Offer{status: :ignored, next_step: step} = offer, step), do: offer
  defp escalation(_offer, _step), do: nil

  @doc "This subject's next rung on its kind's ladder, or nil off it or unignored."
  @spec rung(Ecto.UUID.t(), atom(), String.t(), term()) :: atom() | nil
  def rung(agent_id, kind, type, key) do
    case {ladder({kind, type}), ignored_count(agent_id, key)} do
      {nil, _ignored} -> nil
      {_steps, 0} -> nil
      {steps, ignored} -> Enum.at(steps, ignored - 1)
    end
  end

  defp ignored_count(agent_id, key) do
    case standing(agent_id)[key] do
      %{ignored: n} -> n
      _none -> 0
    end
  end

  @doc "Record one escalation for a repeated operator instruction; never withhold delivery."
  def take_instruction_attention(%Offer{kind: :instruction} = offer, record_notice)
      when is_function(record_notice, 0) do
    serialized(offer.agent_id, fn ->
      same = same_subject(offer.agent_id, :instruction, offer.subject_type, offer.subject_key)
      repeated? = Repo.aggregate(same, :count) > 1

      reported? =
        same
        |> Repo.all()
        |> Enum.any?(&instruction_notice_pending_or_delivered?/1)

      case {repeated?, reported?} do
        {true, false} ->
          record_notice.()
          true

        _ ->
          false
      end
    end)
  end

  def take_instruction_attention(_offer, _record_notice), do: false

  @doc "Bind an escalation to its recorded notice; submission is not confirmed delivery."
  def instruction_notice(%Offer{} = offer, result) do
    step =
      case result do
        {:ok, %Message{id: id}} -> "main_notice:" <> id
        {:error, _} -> "main_notice_failed"
      end

    Repo.update_all(where(Offer, [o], o.id == ^offer.id),
      set: [next_step: step, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp instruction_notice_pending_or_delivered?(%Offer{next_step: "main_notice:" <> id} = offer) do
    case Repo.get(Message, id) do
      %Message{delivery: :delivered} ->
        Repo.update_all(where(Offer, [o], o.id == ^offer.id),
          set: [next_step: "told_main", updated_at: DateTime.utc_now()]
        )

        true

      %Message{delivery: :pending} ->
        true

      _ ->
        false
    end
  end

  defp instruction_notice_pending_or_delivered?(%Offer{next_step: "told_main"}), do: true
  defp instruction_notice_pending_or_delivered?(_offer), do: false

  @doc """
  How many ignored offers hold requirement work back from an agent: the length
  of its ladder.
  """
  def held_after, do: length(@ladders[{:work, "requirement"}])

  @doc """
  Decline an open offer with a reason: `offer_id`, or the
  agent's newest delivered open offer when nil. Pending, failed and withdrawn
  deliveries cannot be declined. Unlinked legacy offers remain eligible.
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
          next_step: declined_step(offer),
          outcome_at: now
        )
        |> Repo.update()
    end
  end

  # A refusal ends it: declining a kind that has a ladder
  # holds its subject back from this agent alone, so the refusal is written on
  # the ladder's terminal rung. `Agents.tell_main_held_back/2` reports that rung
  # once, with the reason -- which is why a refusal does not also
  # send a notice of its own. A kind with no ladder never escalates, so it is
  # recorded as told, the way it always was.
  defp declined_step(offer) do
    case ladder({offer.kind, offer.subject_type}) do
      nil -> "told_main"
      _steps -> "held_back"
    end
  end

  @doc """
  Close this agent's open work offers on `key` as declined: the work was found
  already done when it tried to take it. The system knows the offer
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
    rejectable_offers(agent_id)
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> limit(1)
    |> Repo.one()
  end

  defp open_offer(agent_id, offer_id) do
    case Ecto.UUID.cast(offer_id) do
      {:ok, id} ->
        Repo.one(where(rejectable_offers(agent_id), [o], o.id == ^id))

      :error ->
        nil
    end
  end

  defp rejectable_offers(agent_id) do
    linked = from(link in OfferMessage, select: link.offer_id)

    delivered =
      from(link in OfferMessage,
        join: message in Message,
        on: message.id == link.message_id,
        where: is_nil(message.delivery) or message.delivery == :delivered,
        select: link.offer_id
      )

    from(offer in Offer,
      where: offer.agent_id == ^agent_id and offer.status == :open,
      where: offer.id not in subquery(linked) or offer.id in subquery(delivered)
    )
  end

  @doc """
  This agent's offers that have reached `held_back` and not yet been reported
  to main.

  Not a time window: an ignored offer is settled inside `settle_turn/1`, so
  "settled since" catches it, but a *refused* offer was settled earlier in the
  same turn by the agent's own `Agents.reject_offer/4` -- before the turn end captures
  its timestamp -- and a window would drop exactly the refusal the escalation
  exists to carry. Reported offers are stamped `note: "told_main"`, so each
  reaches main once and a later turn does not repeat it. `note` is free here:
  it carries text only for the `:n_a` kinds, which never reach `held_back`.
  """
  @spec unreported_held_back(Ecto.UUID.t()) :: [Offer.t()]
  def unreported_held_back(agent_id) do
    Offer
    |> where(
      [o],
      o.agent_id == ^agent_id and o.next_step == "held_back" and
        (is_nil(o.note) or o.note != "told_main")
    )
    |> Repo.all()
  end

  @doc "Mark `offer` as reported to main, so the escalation is not repeated."
  @spec mark_reported(Offer.t()) :: :ok
  def mark_reported(%Offer{} = offer) do
    offer
    |> Ecto.Changeset.change(note: "told_main")
    |> Repo.update()

    :ok
  end

  @doc """
  This agent's undelivered instruction offers not yet reported to main --
  `43cdc022`: a delivery failure settled `:undelivered` the same as a decline
  settles `:declined`, but only the decline was ever named to main. Preloads
  the linked message so the caller can read what failed to arrive.
  """
  @spec unreported_undelivered_instructions(Ecto.UUID.t()) :: [Offer.t()]
  def unreported_undelivered_instructions(agent_id) do
    Offer
    |> where(
      [o],
      o.agent_id == ^agent_id and o.kind == :instruction and o.status == :undelivered and
        (is_nil(o.note) or o.note != "told_main")
    )
    |> preload(messages: :message)
    |> Repo.all()
  end

  defp settle([], _agent), do: :ok

  defp settle([first | _] = open, agent) do
    now = DateTime.utc_now()
    calls = Conversations.tool_calls_since(agent.id, first.inserted_at)

    Enum.each(open, fn offer ->
      after_offer = Enum.filter(calls, &(DateTime.compare(&1.at, offer.inserted_at) != :lt))

      case outcome(offer, agent, after_offer) do
        # A pending tap-out (criterion 2162): left exactly as it is, still
        # open, until main resolves it -- not settled at all.
        nil ->
          :ok

        outcome ->
          settled =
            outcome
            |> Map.merge(%{outcome_at: now, updated_at: now})
            |> next_step(offer)

          # Still open when written: a delivery failure marked since the read stands.
          Offer
          |> where([o], o.id == ^offer.id and o.status == :open)
          |> Repo.update_all(set: Map.to_list(settled))
      end
    end)
  end

  # The ladder's next rung, written on the offer it follows, read from the
  # offer's own attempt. A kind not in `@ladders` never escalates. `:open` is
  # included alongside `:ignored` for criterion 2169's exhausted-but-open
  # offer (main's correction on a01ffadb) -- its own rung at the last
  # attempt is "held_back", the same name an :ignored row at that attempt
  # would get.
  defp next_step(%{next_step: _} = settled, _offer), do: settled

  defp next_step(
         %{status: status} = settled,
         %Offer{kind: kind, subject_type: type, attempt: attempt}
       )
       when status in [:ignored, :open] do
    case ladder({kind, type}) do
      nil -> settled
      steps -> Map.put(settled, :next_step, step_name(Enum.at(steps, attempt - 1)))
    end
  end

  defp next_step(settled, _offer), do: settled

  # The rung's name, as the tests and `tell_main_held_back` read it. Past the
  # last rung the offer is already held back and gets no further one.
  defp step_name(nil), do: nil
  defp step_name(step), do: to_string(step)

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
      # A pending tap-out (criterion 2162): not settled at all. Declining it
      # here would be exactly the implicit decline the criterion forbids;
      # settling it claimed would lose the fact that it is still waiting on
      # main. Left alone, the offer stays open on the agent until main
      # resolves the tap-out, at which point this task is no longer blocked
      # by a pending one and the next turn end settles it normally.
      Enum.any?(tasks, &pending_tap_out?/1) ->
        nil

      # Claimed and cancelled: not a decline (product's ruling, issue 75783a94,
      # criterion 1815) --
      # the work returns to the graph as actionable. The abuse case the old
      # decline guarded against (claim and drop the same work forever) is
      # caught by cycle_outcome/1 instead: the third claim-cancel cycle on
      # this subject escalates exactly as an exhausted push does (criterion
      # 2220), rather than every single cancel being punished as a decline.
      Enum.any?(tasks, &cancelled_since?(&1, offer.inserted_at)) ->
        cycle_outcome(prior_cancel_cycles(offer) + 1)

      Enum.any?(tasks, &(started_since?(&1, offer.inserted_at) or start_called?(calls, &1))) ->
        %{status: :claimed}

      # Criterion 2169, main's correction on a01ffadb: an offer whose attempt
      # has reached its own ladder's last rung settles :open, not :ignored
      # like every earlier rung -- standing/1 reads exhaustion from this
      # row's own attempt number directly (not from counting settled
      # :ignored rows), so staying :open here does not break held?/
      # push-suppression (1741). next_step/2 below still annotates it
      # "held_back" so unreported_held_back/1 (which reads next_step alone,
      # not status) still escalates it to main exactly once.
      exhausted_by_ignoring?(offer) ->
        %{status: :open}

      true ->
        %{status: :ignored}
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

  # Older offers keyed on the blocker rather than the task.
  defp outcome(%Offer{kind: :unblocked} = offer, agent, _calls),
    do: claimed_if(resumed?(agent, offer.subject_key))

  defp outcome(%Offer{kind: :denial}, _agent, calls),
    do: claimed_if(called?(calls, "start_task") or called?(calls, "answer_notification"))

  # Claimed when main re-assigned this freed copy: a story with
  # `set_active_story` or an issue with `assign_issue_to_working_copy`,
  # both naming the copy with `working_copy_id`.
  defp outcome(%Offer{kind: :team_free, subject_key: copy_id}, _agent, calls),
    do: claimed_if(assigned_to_copy?(calls, copy_id))

  # How many of this agent's prior offers on the same subject already
  # settled :cancelled -- the count of completed claim-cancel cycles before
  # this one. A fresh push after a claim starts its own attempt back at one
  # (criterion 1815); this counts cycles across that reset, on purpose, since
  # the abuse it is watching for is exactly a claim-cancel repeated through
  # any number of intervening pushes.
  defp prior_cancel_cycles(offer) do
    offer.agent_id
    |> same_subject(offer.kind, offer.subject_type, offer.subject_key)
    |> where([o], o.status == :cancelled)
    |> Repo.aggregate(:count)
  end

  # Criterion 2220: the third claim-cancel cycle on the same subject escalates
  # exactly as an offer exhausted by ignoring does (criterion 2169) -- open,
  # not declined, with next_step read directly off this outcome rather than
  # the push ladder's own attempt (next_step/2's first clause leaves an
  # already-set next_step alone). The first two cycles are a plain cancel:
  # the work returns to the graph, nothing escalated.
  defp cycle_outcome(cycle) when cycle >= 3, do: %{status: :open, next_step: "held_back"}
  defp cycle_outcome(_cycle), do: %{status: :cancelled, reason: "claimed and cancelled"}

  defp exhausted_by_ignoring?(%Offer{kind: kind, subject_type: type, attempt: attempt}) do
    case ladder({kind, type}) do
      nil -> false
      steps -> attempt >= length(steps)
    end
  end

  defp claimed_if(true), do: %{status: :claimed}
  defp claimed_if(false), do: %{status: :ignored}

  # A `start_task` naming this task's requirement on the same kind of entity,
  # directly or through `run_script`. Resuming keeps `started_at`, so the call
  # is the evidence. Not the entity's id: an agent names
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

  defp tasks_on(%Agent{tasks: tasks} = agent, key) when is_binary(key) do
    case String.split(key, ":", parts: 3) do
      [type, id, name] ->
        node = %{entity_type: type, entity_id: resolve_entity_id(agent, type, id), name: name}
        Enum.filter(tasks || [], &Work.task_on_node?(&1, node))

      _ ->
        []
    end
  end

  defp tasks_on(_agent, _key), do: []

  # A work offer's `subject_key` names a story by its number, but
  # `Work.task_on_node?/2` matches a task's `story_id`, the database id.
  defp resolve_entity_id(%Agent{project_id: project_id}, "story", number) do
    case CodeMySpec.Stories.get_story_by_number(%Scope{active_project_id: project_id}, number) do
      nil -> number
      story -> to_string(story.id)
    end
  end

  defp resolve_entity_id(_agent, _type, id), do: id

  # Resuming clears the task's blocker and keeps its `started_at`, so a resumed
  # task is one no longer blocked by this blocker, with the agent back on a task.
  defp resumed?(%Agent{} = agent, blocker_id),
    do: not blocked_by?(agent, blocker_id) and Agent.active_task(agent) != nil

  defp blocked_by?(%Agent{tasks: tasks}, blocker_id),
    do: Enum.any?(tasks || [], &(&1.status == :blocked and &1.blocker_id == blocker_id))

  defp started_since?(%{started_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp started_since?(_task, _since), do: false

  defp resumed_since?(%{status: :active}, _since), do: true

  defp resumed_since?(%{status: :completed, completed_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp resumed_since?(_task, _since), do: false

  defp cancelled_since?(%{status: :cancelled, completed_at: %DateTime{} = at}, since),
    do: DateTime.compare(at, since) != :lt

  defp cancelled_since?(_task, _since), do: false

  defp pending_tap_out?(%{status: :blocked, blocker_type: :tap_out, blocker_resolved_at: nil}),
    do: true

  defp pending_tap_out?(_task), do: false

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
  # An undelivered offer was never made, so it does not count. A cancelled
  # offer was claimed too -- criterion 1815's reset is on the claim, not on
  # staying claimed, so a later cancel (criterion 2220) does not undo it.
  defp attempt(same) do
    last_claimed =
      Repo.one(
        from(o in same, where: o.status in [:claimed, :cancelled], select: max(o.inserted_at))
      )

    since =
      if last_claimed, do: where(same, [o], o.inserted_at > ^last_claimed), else: same

    since |> where([o], o.status != :undelivered) |> Repo.aggregate(:count) |> Kernel.+(1)
  end

  defp insert_offer(agent, kind, type, key, attempt, turn_requested_at) do
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
      template_version: Map.fetch!(@template_versions, kind),
      turn_requested_at: turn_requested_at
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
