defmodule CodeMySpec.Agents.Mailbox.AuthorityTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule BusyTransport do
    def dispatch_message(_copy, _agent, _ref, _text, _timeout), do: {:error, :busy}
  end

  defmodule AcceptingTransport do
    def dispatch_message(_copy, agent, ref, _text, _timeout) do
      scope = %CodeMySpec.Users.Scope{
        active_account_id: agent.account_id,
        active_project_id: agent.project_id,
        active_working_copy_id: agent.working_copy_id
      }

      consumed(Mailbox.consume(scope, agent.id, ref, "engine-one"))
    end

    defp consumed({:ok, _}), do: {:ok, :started}
    defp consumed(error), do: error
  end

  setup do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: :coding,
        status: :running,
        working_copy: "/tmp/mailbox",
        working_copy_id: scope.active_working_copy_id
      })

    CodeMySpecTest.AgentPresence.present(agent)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    {:ok, _} = Mailbox.register(scope, agent.id, "engine-one")
    CodeMySpecTest.AgentTransportRouter.route(scope, AcceptingTransport)
    %{scope: scope, agent: agent, conversation: conversation}
  end

  defp admit(ctx, text) do
    {:ok, message} =
      Conversations.add_message(ctx.conversation, :operator, text, "operator", [],
        delivery: :pending,
        delivery_ref: Ecto.UUID.generate()
      )

    entry = Mailbox.admit(ctx.agent, message, :operator_message)
    {message, entry}
  end

  test "unfenced and stale terminal events cannot settle current work", ctx do
    {message, _} = admit(ctx, "current turn")
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)

    :ok =
      CodeMySpec.Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "turn_started"})

    for event <- [
          %{"kind" => "turn_ended"},
          %{"kind" => "turn_ended", "ref" => message.delivery_ref},
          %{"kind" => "turn_ended", "ref" => message.delivery_ref, "generation" => "old-engine"}
        ] do
      :ok = CodeMySpec.Agents.record_turn_event(ctx.scope, ctx.agent.id, event)
      assert [%{state: :consumed}] = Mailbox.entries(ctx.scope, ctx.agent.id)
      assert Repo.reload!(ctx.agent).turn_started_at
    end
  end

  test "replacement readiness carries the cut turn on and clears the dead turn", ctx do
    Sandbox.mode(Repo, {:shared, self()})
    admit(ctx, "interrupted turn")
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)

    :ok =
      CodeMySpec.Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "turn_started"})

    {:ok, :ok} = Mailbox.register(ctx.scope, ctx.agent.id, "replacement")
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "agents:#{ctx.scope.active_project_id}")

    :ok =
      CodeMySpec.Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
        "kind" => "mailbox_ready",
        "generation" => "replacement",
        "ref" => nil
      })

    assert [%{state: :completed, diagnostic: nil}, %{event: "own_reply"}] =
             Mailbox.entries(ctx.scope, ctx.agent.id)

    assert Repo.reload!(ctx.agent).turn_started_at == nil
    assert_receive {:agent_turn, %{turn_started_at: nil}}
  end

  # Main's cadence check-in at 00:25 ended while the server restarted; its
  # `turn_ended` never arrived, the offer stayed open, and main sat idle until
  # the next cadence (2026-10-13).
  test "a work turn whose end was never reported carries on", ctx do
    {:ok, prompt} =
      Conversations.add_message(ctx.conversation, :operator, "Check-in.", "operator", [])

    offer = Offers.record({:ok, prompt}, ctx.agent, :check_in, {"cadence", nil})

    :ok =
      CodeMySpec.Agents.record_turn_event(ctx.scope, ctx.agent.id, %{"kind" => "turn_started"})

    Mailbox.ready(ctx.scope, ctx.agent.id, "engine-one", nil)

    assert [%{event: "own_reply", state: :claimed, message_id: carry_on}] =
             Mailbox.entries(ctx.scope, ctx.agent.id)

    assert [%{"text" => text}] = Repo.get!(Conversations.Message, carry_on).content
    assert text =~ "could not reach the server"
    assert Repo.reload!(offer).status == :superseded
    assert Repo.reload!(ctx.agent).turn_started_at == nil
  end

  test "an idle engine with no turn under way is not carried on", ctx do
    Mailbox.ready(ctx.scope, ctx.agent.id, "engine-one", nil)

    assert Mailbox.entries(ctx.scope, ctx.agent.id) == []
  end

  test "busy leaves the only payload queued in the database", ctx do
    CodeMySpecTest.AgentTransportRouter.route(ctx, BusyTransport)
    {message, _} = admit(ctx, "first")
    assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert [%{state: :queued}] = Mailbox.entries(ctx.scope, ctx.agent.id)
    assert Repo.get!(Conversations.Message, message.id).delivery == :pending
  end

  defmodule HarnessNotConnectedTransport do
    def dispatch_message(_copy, _agent, _ref, _text, _timeout),
      do: {:error, :harness_not_connected}
  end

  # Criterion 2042: a transport's definite refusal is not a mere missed
  # acknowledgement -- it settles the entry :failed (not :queued for retry,
  # the way :busy above leaves it) and carries the message and its offer
  # down with it, so main can tell an undelivered instruction from one that
  # was merely slow.
  test "a harness reporting it cannot be reached settles delivery failed and its offer undelivered",
       ctx do
    CodeMySpecTest.AgentTransportRouter.route(ctx, HarnessNotConnectedTransport)
    {message, _} = admit(ctx, "an instruction")
    offer = Offers.record_or_link({:ok, message}, ctx.agent, :instruction, {"notice", nil})

    assert {:error, :harness_not_connected} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert [%{state: :failed}] = Mailbox.entries(ctx.scope, ctx.agent.id)
    assert Repo.get!(Conversations.Message, message.id).delivery == :failed
    assert Repo.reload!(offer).status == :undelivered
  end

  test "FIFO advances only after the consumed turn finishes", ctx do
    {first, _} = admit(ctx, "first")
    {second, _} = admit(ctx, "second")
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert [%{state: :consumed}, %{state: :queued}] = Mailbox.entries(ctx.scope, ctx.agent.id)
    assert {:ok, _} = Mailbox.finish(ctx.scope, ctx.agent.id, first.delivery_ref, "engine-one")
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert Repo.get!(Conversations.Message, second.id).delivery == :delivered
  end

  test "duplicate consumption cannot authorize another execution", ctx do
    {message, _} = admit(ctx, "one execution")
    Mailbox.pump(ctx.scope, ctx.agent.id)

    assert {:error, :not_claimed} =
             Mailbox.consume(ctx.scope, ctx.agent.id, message.delivery_ref, "engine-two")
  end

  test "withdrawal wins before consumption and prevents stale dispatch", ctx do
    {message, entry} = admit(ctx, "take back")
    entry |> Ecto.Changeset.change(state: :claimed) |> Repo.update!()

    assert {:ok, %{delivery: :withdrawn}} =
             Mailbox.withdraw(ctx.scope, ctx.agent.id, message.delivery_ref)

    assert {:error, :not_claimed} =
             Mailbox.consume(ctx.scope, ctx.agent.id, message.delivery_ref, "engine-one")
  end

  test "consumption wins and withdrawal refuses", ctx do
    {message, _} = admit(ctx, "already owned")
    Mailbox.pump(ctx.scope, ctx.agent.id)

    assert {:error, :already_delivered} =
             Mailbox.withdraw(ctx.scope, ctx.agent.id, message.delivery_ref)
  end

  test "stale terminal event cannot release the current turn", ctx do
    {message, _} = admit(ctx, "current")
    Mailbox.pump(ctx.scope, ctx.agent.id)
    Mailbox.finish(ctx.scope, ctx.agent.id, message.delivery_ref, "older-engine")
    assert [%{state: :consumed}] = Mailbox.entries(ctx.scope, ctx.agent.id)
  end

  test "unknown terminal outcome stays visible and is not replayed", ctx do
    {_message, _} = admit(ctx, "uncertain")
    Mailbox.pump(ctx.scope, ctx.agent.id)
    Mailbox.ready(ctx.scope, ctx.agent.id, "engine-one", nil)

    assert [%{state: :uncertain, diagnostic: diagnostic}] =
             Mailbox.entries(ctx.scope, ctx.agent.id)

    assert diagnostic =~ "unknown"
    assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
  end

  test "wrong account cannot consume or withdraw", ctx do
    {message, entry} = admit(ctx, "private")
    entry |> Ecto.Changeset.change(state: :claimed) |> Repo.update!()
    scope = %{ctx.scope | active_account_id: Ecto.UUID.generate()}

    assert {:error, :not_found} =
             Mailbox.consume(scope, ctx.agent.id, message.delivery_ref, "engine-one")

    assert {:error, :not_pending} = Mailbox.withdraw(scope, ctx.agent.id, message.delivery_ref)
  end

  test "standing down an agent prevents consumption of its outstanding claim", ctx do
    {message, entry} = admit(ctx, "held")
    entry |> Ecto.Changeset.change(state: :claimed) |> Repo.update!()
    ctx.agent |> Ecto.Changeset.change(off_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, _} =
             Mailbox.consume(ctx.scope, ctx.agent.id, message.delivery_ref, "engine-one")
  end

  test "a replacement engine fences delayed claims from the old engine", ctx do
    {message, entry} = admit(ctx, "survives restart")
    entry |> Ecto.Changeset.change(state: :claimed) |> Repo.update!()
    assert {:ok, _} = Mailbox.register(ctx.scope, ctx.agent.id, "replacement")

    assert {:error, :stale_engine} =
             Mailbox.consume(ctx.scope, ctx.agent.id, message.delivery_ref, "engine-one")

    assert {:ok, _} =
             Mailbox.consume(ctx.scope, ctx.agent.id, message.delivery_ref, "replacement")
  end

  test "a stale reconnect cannot quarantine a current engine", ctx do
    {message, _} = admit(ctx, "current")
    Mailbox.pump(ctx.scope, ctx.agent.id)
    assert {:error, :stale_engine} = Mailbox.ready(ctx.scope, ctx.agent.id, "old", nil)
    assert {:ok, _} = Mailbox.ready(ctx.scope, ctx.agent.id, "engine-one", message.delivery_ref)
    assert [%{state: :consumed}] = Mailbox.entries(ctx.scope, ctx.agent.id)
  end

  defmodule CurrentEngineTransport do
    def dispatch_message(_copy, agent, ref, text, _timeout) do
      send(Application.get_env(:code_my_spec, :test_mailbox_owner), {:dispatched, text})
      generation = CodeMySpec.Repo.reload!(agent).mailbox_generation

      scope = %CodeMySpec.Users.Scope{
        active_account_id: agent.account_id,
        active_project_id: agent.project_id,
        active_working_copy_id: agent.working_copy_id
      }

      consumed(Mailbox.consume(scope, agent.id, ref, generation))
    end

    defp consumed({:ok, _}), do: {:ok, :started}
    defp consumed(error), do: error
  end

  test "a replaced engine's turn carries on before the mail queued behind it", ctx do
    {first, _} = admit(ctx, "cut part-way")
    {second, _} = admit(ctx, "still waiting")
    Mailbox.pump(ctx.scope, ctx.agent.id)
    Mailbox.register(ctx.scope, ctx.agent.id, "replacement")
    Mailbox.ready(ctx.scope, ctx.agent.id, "replacement", nil)

    assert [
             %{state: :completed, diagnostic: nil, delivery_ref: ref},
             %{state: :queued},
             %{state: :claimed, event: "own_reply"}
           ] = Mailbox.entries(ctx.scope, ctx.agent.id)

    assert ref == first.delivery_ref
    assert Repo.get!(Conversations.Message, second.id).delivery == :pending

    Application.put_env(:code_my_spec, :test_mailbox_owner, self())
    on_exit(fn -> Application.delete_env(:code_my_spec, :test_mailbox_owner) end)
    CodeMySpecTest.AgentTransportRouter.route(ctx, CurrentEngineTransport)

    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert_received {:dispatched, text}

    assert text =~ "Carry on from your last step",
           "the queued message went before the turn it was waiting behind"

    refute text =~ "cut part-way", "the cut turn's message was delivered a second time"

    assert [%{mailbox_state: "queued"}] = Mailbox.waiting_messages(ctx.conversation),
           "a finished, continued turn was still shown as waiting or interrupted"
  end

  test "a restart caught before consumption puts the claim back, behind the carry-on", ctx do
    CodeMySpecTest.AgentTransportRouter.route(ctx, BusyTransport)
    {message, _} = admit(ctx, "not yet taken")
    {:ok, entry} = Repo.transaction(fn -> Mailbox.entries(ctx.scope, ctx.agent.id) end)
    [%{} = queued] = entry
    queued |> Ecto.Changeset.change(state: :claimed) |> Repo.update!()

    {:ok, _} = Mailbox.carry_on(ctx.scope, ctx.agent.id)

    assert [%{state: :queued, message_id: id}, %{state: :claimed, event: "own_reply"}] =
             Mailbox.entries(ctx.scope, ctx.agent.id)

    assert id == message.id
  end

  defmodule LostAckTransport do
    def dispatch_message(copy, agent, ref, text, timeout) do
      {:ok, :started} = AcceptingTransport.dispatch_message(copy, agent, ref, text, timeout)
      {:error, :message_timed_out}
    end
  end

  test "lost transport acknowledgement cannot obscure committed consumption", ctx do
    CodeMySpecTest.AgentTransportRouter.route(ctx, LostAckTransport)
    {message, _} = admit(ctx, "accepted once")
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert Repo.get!(Conversations.Message, message.id).delivery == :delivered
    assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert [%{state: :consumed, diagnostic: nil}] = Mailbox.entries(ctx.scope, ctx.agent.id)
  end

  test "legacy pending payloads are visible but never imported for automatic replay", ctx do
    {:ok, _} =
      Conversations.add_message(ctx.conversation, :operator, "legacy", "operator", [],
        delivery: :pending,
        delivery_ref: Ecto.UUID.generate()
      )

    assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert [] = Mailbox.entries(ctx.scope, ctx.agent.id)

    assert [%{mailbox_state: "legacy_unknown", delivery_diagnostic: reason}] =
             Mailbox.waiting_messages(ctx.conversation)

    assert reason =~ "not be replayed"
  end
end
