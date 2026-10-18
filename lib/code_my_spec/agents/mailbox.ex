defmodule CodeMySpec.Agents.Mailbox do
  @moduledoc """
  The durable, ordered mailbox for an agent (07569d21, story 1051).

  Only queued entries can be claimed. Only the current claim can be consumed,
  and consumption commits before the harness may execute. Consumption is not
  completion or compliance. A lost acknowledgement never authorizes replay.
  The engine owns one executing turn; it owns no waiting payloads.
  """
  import Ecto.Query
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.CompletionHandoffs
  alias CodeMySpec.Agents.Mailbox.Entry
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Presence
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo

  @active [:claimed, :consumed, :uncertain]

  @doc "Register the sole engine started by the working-copy supervisor."
  def register(scope, agent_id, generation) do
    Repo.transaction(fn ->
      agent = lock_agent!(scope, agent_id)
      agent |> Ecto.Changeset.change(mailbox_generation: generation) |> Repo.update!()
      :ok
    end)
  end

  @doc """
  Called in the admission transaction, after the message and its offer exist.

  `send_now: true` lets the message into a running turn at its next tool
  boundary (`take_send_now/3`); otherwise it waits for the turn to end.
  """
  def admit(agent, message, event, opts \\ []) do
    scope = %CodeMySpec.Users.Scope{
      active_account_id: agent.account_id,
      active_project_id: agent.project_id
    }

    {:ok, entry} =
      Repo.transaction(fn ->
        lock_agent!(scope, agent.id)

        Repo.insert!(%Entry{
          agent_id: agent.id,
          message_id: message.id,
          delivery_ref: message.delivery_ref,
          event: to_string(event),
          send_now: Keyword.get(opts, :send_now, false),
          state: :queued
        })
      end)

    entry
  end

  @doc "One pump, shared by admission, terminal turns, startup and reconnect."
  def pump(scope, agent_id, timeout \\ 15_000) do
    case claim(scope, agent_id) do
      {:ok, {agent, entry}} ->
        message = Repo.get!(Message, entry.message_id)

        result =
          Transport.dispatch_message(
            agent.working_copy_id,
            agent,
            entry.delivery_ref,
            Message.text(message),
            timeout
          )

        reconcile_dispatch(scope, agent_id, entry, result)

      {:ok, nil} ->
        {:ok, :queued}

      error ->
        error
    end
  end

  defp claim(scope, agent_id) do
    Repo.transaction(fn ->
      agent = lock_agent!(scope, agent_id)

      active = Repo.one(from e in Entry, where: e.agent_id == ^agent_id and e.state in ^@active)

      entry =
        Repo.one(
          from e in Entry,
            where: e.agent_id == ^agent_id and e.state == :queued,
            # A message sent now that no tool boundary took goes ahead of the
            # rest when the turn ends.
            order_by: [desc_nulls_last: e.send_now, asc: e.id],
            limit: 1
        )

      claim_entry(agent, active, entry)
    end)
  end

  defp claim_entry(agent, %{state: :claimed} = entry, _queued) do
    case may_consume(agent) do
      :ok -> {agent, entry}
      _ -> nil
    end
  end

  defp claim_entry(agent, nil, %Entry{} = entry) do
    case may_consume(agent) do
      :ok -> {agent, change_entry(entry, %{state: :claimed, claimed_at: DateTime.utc_now()})}
      _ -> nil
    end
  end

  defp claim_entry(_agent, _active, _entry), do: nil

  @lost_turn "Your turn ended while the harness could not reach the server, so how it " <>
               "ended was not recorded. Everything that was recorded is above; a call with " <>
               "no recorded result may or may not have taken effect. Carry on from your " <>
               "last step."

  @doc "The current engine reports its generation and executing ref after startup/reconnect."
  def ready(scope, agent_id, generation, current_ref) do
    Repo.transaction(fn ->
      agent = lock_agent!(scope, agent_id)
      if agent.mailbox_generation != generation, do: Repo.rollback(:stale_engine)

      active =
        Repo.one(
          from e in Entry, where: e.agent_id == ^agent_id and e.state in [:consumed, :uncertain]
        )

      result = reconcile_engine(agent, active, generation, current_ref)
      :ok = recover_unreported_turn(agent, active, current_ref)

      if is_nil(current_ref),
        do: agent |> Ecto.Changeset.change(turn_started_at: nil) |> Repo.update!()

      result
    end)
    |> publish_transition()
  end

  defp reconcile_engine(_agent, nil, _generation, _ref), do: :ok

  defp reconcile_engine(_agent, %{generation: generation, delivery_ref: ref}, generation, ref),
    do: :ok

  defp reconcile_engine(_agent, %{generation: generation} = entry, generation, _ref) do
    change_entry(entry, %{
      state: :uncertain,
      diagnostic:
        "Engine is idle but no terminal receipt was recorded; execution outcome is unknown."
    })
  end

  # The engine that consumed this was replaced mid-turn — its process crashed
  # and was restarted. The turn carries on.
  defp reconcile_engine(agent, _entry, _new_generation, _ref), do: carry_on_locked(agent)

  # A turn this side saw start, that the engine says is over, and that no entry
  # here accounts for: a work or cadence turn whose `turn_ended` went out while
  # the channel was down. Nothing settled it, so its offer stayed open and the
  # agent sat idle until something else woke it — main's check-in at 00:25,
  # cut by a server restart, until its next cadence (2026-10-13).
  defp recover_unreported_turn(%{turn_started_at: %DateTime{}} = agent, nil, nil) do
    :ok = Offers.supersede_queued(agent.id)
    _ = carry_on_locked(agent, @lost_turn)
    :ok
  end

  defp recover_unreported_turn(_agent, _active, _ref), do: :ok

  @carry_on "The harness restarted part-way through your turn. Everything up to that " <>
              "point is above, including each call you made and what it returned; a call " <>
              "with no recorded result may or may not have taken effect. Carry on from " <>
              "your last step."

  @doc """
  Carry on a turn a restart cut, ahead of anything queued (story 1051).

  The agent comes back holding its conversation as recorded, so the turn is
  continued rather than replayed: the message it was answering is already in
  that conversation, and what it is sent is that the harness restarted and to
  carry on from its last step. Entered claimed rather than queued, because a
  claim is what the pump dispatches first — what is queued behind it is
  delivered when the continued turn ends, in order, as always.

  The cut turn's own entry is complete: its message was delivered. A claim the
  restart caught before consumption was never delivered, so it goes back to
  the head of the queue.
  """
  def carry_on(scope, agent_id) do
    Repo.transaction(fn -> scope |> lock_agent!(agent_id) |> carry_on_locked() end)
    |> publish_transition()
  end

  defp carry_on_locked(agent, text \\ @carry_on) do
    now = DateTime.utc_now()

    for entry <-
          Repo.all(from e in Entry, where: e.agent_id == ^agent.id and e.state in ^@active) do
      case entry do
        # An earlier restart's carry-on nobody took; this one replaces it.
        %{state: :claimed, event: "own_reply"} ->
          change_entry(entry, %{state: :withdrawn, finished_at: now})

          {:ok, _} =
            Conversations.set_delivery(Repo.get!(Message, entry.message_id), :withdrawn,
              broadcast: false
            )

        %{state: :claimed} ->
          change_entry(entry, %{state: :queued, claimed_at: nil})

        _cut ->
          change_entry(entry, %{state: :completed, finished_at: now, diagnostic: nil})
      end
    end

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        agent.account_id,
        agent.project_id,
        agent.id
      )

    ref = Ecto.UUID.generate()

    {:ok, message} =
      Conversations.add_message(conversation, :operator, text, "system:restart", [],
        delivery: :pending,
        delivery_ref: ref
      )

    Offers.record({:ok, message}, agent, :resume, {"restart", nil})

    Repo.insert!(%Entry{
      agent_id: agent.id,
      message_id: message.id,
      delivery_ref: ref,
      event: "own_reply",
      state: :claimed,
      claimed_at: now
    })
  end

  @doc "Bounded recovery of durable waiting work; no in-memory list of payloads."
  def reconcile_pending do
    ids =
      Repo.all(
        from e in Entry,
          where: e.state in [:queued, :claimed],
          distinct: e.agent_id,
          select: e.agent_id,
          limit: 100
      )

    ids
    |> Task.async_stream(
      fn id ->
        agent = Repo.get!(Agent, id)

        scope = %CodeMySpec.Users.Scope{
          active_account_id: agent.account_id,
          active_project_id: agent.project_id,
          active_working_copy_id: agent.working_copy_id
        }

        pump(scope, id)
      end,
      max_concurrency: 4,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  # Busy means no admission happened at the engine. The payload remains here.
  defp reconcile_dispatch(scope, agent_id, entry, {:error, :busy}) do
    transition(scope, agent_id, entry.delivery_ref, fn
      %{state: :claimed} = current -> change_entry(current, %{state: :queued, claimed_at: nil})
      current -> current
    end)

    {:ok, :queued}
  end

  # Delivery is established by consume/4, never by a transport acknowledgement.
  defp reconcile_dispatch(_scope, _agent_id, _entry, {:ok, :started}), do: {:ok, :started}

  defp reconcile_dispatch(scope, agent_id, entry, {:error, reason} = error) do
    case transition(scope, agent_id, entry.delivery_ref, fn
           %{state: :claimed} = current ->
             change_entry(current, %{diagnostic: "Dispatch unconfirmed: #{inspect(reason)}"})

           current ->
             current
         end) do
      {:ok, %{state: state}} when state in [:consumed, :completed] -> {:ok, :started}
      _ -> error
    end
  end

  @doc "Authenticated harness admission: the only authorization to execute a mailbox message."
  def consume(scope, agent_id, ref, generation) when is_binary(generation) do
    transition(scope, agent_id, ref, fn
      %{state: :claimed} = entry ->
        agent = Repo.get!(Agent, agent_id)
        if agent.mailbox_generation != generation, do: Repo.rollback(:stale_engine)

        case may_consume(agent) do
          :ok ->
            entry =
              change_entry(entry, %{
                state: :consumed,
                generation: generation,
                consumed_at: DateTime.utc_now(),
                diagnostic: nil
              })

            {:ok, _} =
              Conversations.set_delivery(Repo.get!(Message, entry.message_id), :delivered,
                broadcast: false
              )

            CompletionHandoffs.delivered(entry.message_id, agent)
            entry

          {:error, reason} ->
            Repo.rollback(reason)
        end

      _ ->
        Repo.rollback(:not_claimed)
    end)
  end

  defp may_consume(agent) do
    with :ok <- Transport.deliverable(agent) do
      if Presence.present?(agent.project_id, agent.id), do: :ok, else: {:error, :not_running}
    end
  end

  @doc "Terminal evidence is tied to the consumed ref and engine generation."
  def finish(scope, agent_id, ref, generation, outcome \\ :completed) do
    transition(scope, agent_id, ref, fn
      %{state: state, generation: ^generation} = entry when state in [:consumed, :uncertain] ->
        change_entry(entry, %{state: outcome, finished_at: DateTime.utc_now(), diagnostic: nil})

      _entry ->
        Repo.rollback(:stale_completion)
    end)
  end

  @doc "Put a queued message at the head of the queue, to be the agent's next turn (story 1051)."
  def send_now(scope, agent_id, ref) do
    transition(scope, agent_id, ref, fn
      %{state: :queued} = entry -> change_entry(entry, %{send_now: true})
      _ -> Repo.rollback(:already_delivered)
    end)
  end

  @doc "Withdrawal and consumption arbitrate on the same durable claim."
  def withdraw(scope, agent_id, ref) do
    case transition(scope, agent_id, ref, fn
           %{state: state} = entry when state in [:queued, :claimed] ->
             entry = change_entry(entry, %{state: :withdrawn, finished_at: DateTime.utc_now()})

             {:ok, message} =
               Conversations.set_delivery(Repo.get!(Message, entry.message_id), :withdrawn,
                 broadcast: false
               )

             message

           _ ->
             Repo.rollback(:already_delivered)
         end) do
      {:error, :not_found} -> {:error, :not_pending}
      result -> result
    end
  end

  @doc """
  Delivery details for the existing conversation UI, derived from mailbox evidence.

  Only what is still on its way: a pending message, or one whose outcome is
  uncertain until a receipt arrives. A finished entry keeps its diagnostic as a
  record, but it is nothing the person can act on, and listing it kept retired
  notes on screen for good.
  """
  def waiting_messages(conversation) do
    Repo.all(
      from m in Message,
        left_join: e in Entry,
        on: e.message_id == m.id,
        where:
          m.conversation_id == ^conversation.id and
            (m.delivery == :pending or e.state == :uncertain),
        order_by: m.inserted_at,
        select: {m, e}
    )
    |> Enum.map(fn
      {message, nil} ->
        %{
          message
          | mailbox_state: "legacy_unknown",
            delivery_diagnostic:
              "Legacy delivery is unconfirmed; it will not be replayed automatically."
        }

      {message, %{state: :queued, send_now: true} = entry} ->
        %{message | mailbox_state: "send_now", delivery_diagnostic: entry.diagnostic}

      {message, entry} ->
        %{message | mailbox_state: to_string(entry.state), delivery_diagnostic: entry.diagnostic}
    end)
  end

  def pending?(agent_id),
    do:
      Repo.exists?(
        from e in Entry,
          where: e.agent_id == ^agent_id and e.state in [:queued, :claimed, :consumed, :uncertain]
      )

  def entries(scope, agent_id) do
    case Repo.get_by(Agent,
           id: agent_id,
           account_id: scope.active_account_id,
           project_id: scope.active_project_id
         ) do
      nil -> []
      _ -> Repo.all(from e in Entry, where: e.agent_id == ^agent_id, order_by: e.id)
    end
  end

  defp transition(scope, agent_id, ref, fun) do
    Repo.transaction(fn ->
      lock_agent!(scope, agent_id)

      case Repo.get_by(Entry, agent_id: agent_id, delivery_ref: ref) do
        nil -> Repo.rollback(:not_found)
        entry -> fun.(entry)
      end
    end)
    |> publish_transition()
  end

  # Refresh projections after the transaction commits, including diagnostics
  # that do not change the conversation message's delivery field.
  def publish(message) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      Conversations.conversation_topic(message.conversation_id),
      {:message_updated, message}
    )
  end

  defp publish_transition({:ok, %Entry{} = entry} = result) do
    publish(Repo.get!(Message, entry.message_id))
    result
  end

  defp publish_transition({:ok, %Message{} = message} = result) do
    publish(message)
    result
  end

  defp publish_transition(result), do: result

  defp lock_agent!(scope, agent_id) do
    case Repo.one(
           from a in Agent,
             where:
               a.id == ^agent_id and
                 a.account_id == ^scope.active_account_id and
                 a.project_id == ^scope.active_project_id,
             lock: "FOR UPDATE"
         ) do
      nil -> Repo.rollback(:not_found)
      agent -> agent
    end
  end

  defp change_entry(entry, attrs), do: entry |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
