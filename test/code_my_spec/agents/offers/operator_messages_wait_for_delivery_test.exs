defmodule CodeMySpec.Agents.Offers.OperatorMessagesWaitForDeliveryTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: false,
        working_copy: "/tmp/queued-offer-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id,
        turn_started_at: DateTime.utc_now()
      })

    AgentPresence.present(agent)
    {:ok, _} = Agents.Mailbox.register(scope, agent.id, "test-engine")

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent, conversation: conversation}
  end

  test "the next turn acknowledges a delivered instruction without tool use", ctx do
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, "What is the status?")
    assert_received {:agent_dispatch, _, ref, "What is the status?"}

    assert :ok =
             Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
               "kind" => "turn_started"
             })

    assert [%{status: :open}] = Offers.list_for_agent(ctx.agent.id)

    {:ok, _} = Agents.Mailbox.consume(ctx.scope, ctx.agent.id, ref, "test-engine")

    assert [%{status: :open}] = Offers.list_for_agent(ctx.agent.id)

    assert :ok =
             Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
               "kind" => "turn_started"
             })

    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :n_a
    assert offer.note =~ "delivered/seen"
  end

  test "repeated instructions reach the agent verbatim and notify main once", ctx do
    Sandbox.mode(Repo, {:shared, self()})
    {:ok, _} = CodeMySpec.Staffing.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    {:ok, main} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :main,
        status: :running,
        continuous: true,
        working_copy: "/tmp/instruction-main",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(main)

    id = ctx.agent.id
    main_id = main.id

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, id, "Keep my exact words.")
    assert_received {:agent_dispatch, ^id, first_ref, "Keep my exact words."}
    {:ok, _} = Agents.Mailbox.consume(ctx.scope, id, first_ref, "test-engine")
    {:ok, _} = Agents.Mailbox.finish(ctx.scope, id, first_ref, "test-engine")
    refute_received {:agent_dispatch, ^main_id, _, _}

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, id, "Keep my exact words.")
    assert_received {:agent_dispatch, ^id, second_ref, "Keep my exact words."}
    {:ok, _} = Agents.Mailbox.consume(ctx.scope, id, second_ref, "test-engine")
    {:ok, _} = Agents.Mailbox.finish(ctx.scope, id, second_ref, "test-engine")
    assert_receive {:agent_dispatch, ^main_id, _, notice}, 5_000
    assert notice =~ "repeated an instruction"
    assert notice =~ id

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, id, "Keep my exact words.")
    assert_received {:agent_dispatch, ^id, third_ref, "Keep my exact words."}
    assert length(Enum.uniq([first_ref, second_ref, third_ref])) == 3
    assert [first, second, third] = Offers.list_for_agent(id)
    assert first.status == :superseded
    assert second.status == :superseded
    assert String.starts_with?(second.next_step, "main_notice:")
    notice_id = String.replace_prefix(second.next_step, "main_notice:", "")
    assert Repo.get!(Message, notice_id).delivery == :pending
    assert third.status == :open
    assert third.attempt == 3
    assert Offers.standing(id) == %{}

    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)

    refute_received {:agent_dispatch, ^main_id, _, _}
  end

  test "failed main escalation recovers on a repeat and pending or delivered notice prevents duplicates",
       ctx do
    Sandbox.mode(Repo, {:shared, self()})
    {:ok, _} = CodeMySpec.Staffing.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    {:ok, main} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :main,
        status: :running,
        continuous: true,
        working_copy: "/tmp/escalation-recovery-main",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    text = "Recover this exact instruction."
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, text)
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, text)
    [_, second] = Offers.list_for_agent(ctx.agent.id)
    notice_id = String.replace_prefix(second.next_step, "main_notice:", "")
    assert Repo.get!(Message, notice_id).delivery == :failed
    refute second.next_step == "told_main"

    AgentPresence.present(main)
    {:ok, _} = Agents.Mailbox.register(ctx.scope, main.id, "test-engine")
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, text)
    main_id = main.id
    assert_receive {:agent_dispatch, ^main_id, ref, notice}, 5000
    assert notice =~ "repeated an instruction"
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, text)
    refute_receive {:agent_dispatch, ^main_id, _, _}, 100

    {:ok, _} = Agents.Mailbox.consume(ctx.scope, main.id, ref, "test-engine")

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, text)
    refute_receive {:agent_dispatch, ^main_id, _, _}, 100
    assert Enum.any?(Offers.list_for_agent(ctx.agent.id), &(&1.next_step == "told_main"))

    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn monitor -> assert_receive {:DOWN, ^monitor, _, _, _}, 5000 end)
  end

  test "a delivery event arriving before the transport reply is retained", ctx do
    CodeMySpecTest.AgentTransportRouter.route(
      ctx.scope,
      CodeMySpecTest.DeliveryBeforeAckTransport
    )

    assert {:ok, :started, message} =
             Agents.dispatch_message(ctx.scope, ctx.agent.id, "Inspect this.", :operator_message)

    assert message.delivery == :delivered
    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert [link] = offer.messages
    assert link.message_id == message.id
    assert :ok = Offers.settle_turn(ctx.agent)
    assert [settled] = Offers.list_for_agent(ctx.agent.id)
    assert settled.status == :n_a
  end

  test "activity before delivery is not judged as instruction compliance", ctx do
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, "Inspect this.")
    assert_received {:agent_dispatch, _, ref, "Inspect this."}

    assert {:ok, _} =
             Conversations.add_tool_call(
               ctx.conversation,
               Ecto.UUID.generate(),
               "read",
               %{},
               "coding"
             )

    {:ok, _} = Agents.Mailbox.consume(ctx.scope, ctx.agent.id, ref, "test-engine")

    assert :ok = Offers.settle_turn(ctx.agent)
    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :n_a
  end

  test "a delivered instruction is seen without judging the tools used", ctx do
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, "Inspect this.")
    assert_received {:agent_dispatch, _, ref, "Inspect this."}

    {:ok, _} = Agents.Mailbox.consume(ctx.scope, ctx.agent.id, ref, "test-engine")

    assert {:ok, _} =
             Conversations.add_tool_call(
               ctx.conversation,
               Ecto.UUID.generate(),
               "read",
               %{},
               "coding"
             )

    assert :ok = Offers.settle_turn(ctx.agent)
    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :n_a
  end

  test "unconfirmed transport leaves the durable message pending without accusing the agent",
       ctx do
    CodeMySpecTest.AgentTransportRouter.route(ctx, CodeMySpecTest.UnreachableMachine)

    assert {:error, :harness_not_connected} =
             Agents.message_agent(ctx.scope, ctx.agent.id, "Inspect this.")

    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :open
    assert [link] = offer.messages
    assert Repo.get!(Message, link.message_id).delivery == :pending
    assert :ok = Offers.settle_turn(ctx.agent)
    assert [settled] = Offers.list_for_agent(ctx.agent.id)
    assert settled.status == :open
  end

  test "the development route also queues and measures its instruction", ctx do
    assert {:ok, :queued} = Agents.message_any_agent(ctx.agent.id, "Inspect this.", :no_wait)
    assert_received {:agent_dispatch, _, ref, "Inspect this."}
    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert [link] = offer.messages
    assert Repo.get!(Message, link.message_id).delivery_ref == ref
  end

  test "an operator message is queued with an offer and is not settled before delivery", ctx do
    id = ctx.agent.id

    assert {:ok, :queued} =
             Agents.message_agent(ctx.scope, id, "Please inspect the failing test.")

    assert_received {:agent_dispatch, ^id, ref, "Please inspect the failing test."}
    refute_received {:agent_message, _, _}

    assert [offer] = Offers.list_for_agent(id)
    assert offer.status == :open
    assert [link] = offer.messages
    message = Repo.get!(Message, link.message_id)
    assert message.delivery == :pending
    assert message.delivery_ref == ref
    assert Message.text(message) == "Please inspect the failing test."

    assert :ok = Offers.settle_turn(ctx.agent)
    assert [pending] = Offers.list_for_agent(id)
    assert pending.status == :open
    assert pending.outcome_at == nil

    {:ok, _} = Agents.Mailbox.consume(ctx.scope, id, ref, "test-engine")

    assert Repo.get!(Message, message.id).delivery == :delivered

    assert :ok = Offers.settle_turn(ctx.agent)
    assert [settled] = Offers.list_for_agent(id)
    assert settled.status == :n_a
    assert settled.outcome_at
  end

  test "default rejection skips a newer pending instruction", ctx do
    delivered = rejection_offer(ctx, :delivered, "received work")
    pending = rejection_offer(ctx, :pending, "waiting instruction")

    {:ok, _} =
      delivered
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update()

    assert {:ok, declined} = Offers.reject(ctx.agent.id, nil, "Decline received work")
    assert declined.id == delivered.id
    assert declined.reason == "Decline received work"
    assert Repo.reload!(pending).status == :open
  end

  test "explicit rejection refuses pending, failed and withdrawn deliveries", ctx do
    for delivery <- [:pending, :failed, :withdrawn] do
      offer = rejection_offer(ctx, delivery, "unseen #{delivery}")
      assert {:error, :not_found} = Offers.reject(ctx.agent.id, offer.id, "Unrelated refusal")
      assert Repo.reload!(offer).status == :open
      assert Repo.reload!(offer).reason == nil
    end
  end

  test "only pending offers cannot be declined by default", ctx do
    offer = rejection_offer(ctx, :pending, "still queued")
    assert {:error, :not_found} = Offers.reject(ctx.agent.id, nil, "Unrelated refusal")
    assert Repo.reload!(offer).status == :open
  end

  test "delivered identity and unlinked legacy offers remain rejectable", ctx do
    delivered = rejection_offer(ctx, :delivered, "received instruction")
    legacy = Offers.record(:ok, ctx.agent, :work, {"requirement", "legacy"})
    assert {:ok, %{id: id}} = Offers.reject(ctx.agent.id, delivered.id, "Received and declined")
    assert id == delivered.id
    assert Repo.reload!(legacy).status == :open
    assert {:error, :not_found} = Offers.reject(Ecto.UUID.generate(), legacy.id, "Foreign agent")
    assert {:ok, %{id: legacy_id}} = Offers.reject(ctx.agent.id, legacy.id, "Legacy declined")
    assert legacy_id == legacy.id
  end

  defp rejection_offer(ctx, delivery, text) do
    {:ok, message} =
      Conversations.add_message(ctx.conversation, :operator, text, "operator", [],
        delivery: delivery,
        delivery_ref: Ecto.UUID.generate()
      )

    Offers.record({:ok, message}, ctx.agent, :instruction, {"message", text})
  end
end
