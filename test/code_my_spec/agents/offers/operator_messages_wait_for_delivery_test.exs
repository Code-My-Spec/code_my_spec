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
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
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

    assert :ok =
             Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
               "kind" => "message_delivered",
               "ref" => ref
             })

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

    id = ctx.agent.id
    main_id = main.id

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, id, "Keep my exact words.")
    assert_received {:agent_dispatch, ^id, first_ref, "Keep my exact words."}
    refute_received {:agent_dispatch, ^main_id, _, _}

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, id, "Keep my exact words.")
    assert_received {:agent_dispatch, ^id, second_ref, "Keep my exact words."}
    assert_receive {:agent_dispatch, ^main_id, _, notice}, 5_000
    assert notice =~ "repeated an instruction"
    assert notice =~ id

    assert {:ok, :queued} = Agents.message_agent(ctx.scope, id, "Keep my exact words.")
    assert_received {:agent_dispatch, ^id, third_ref, "Keep my exact words."}
    assert length(Enum.uniq([first_ref, second_ref, third_ref])) == 3
    assert [first, second, third] = Offers.list_for_agent(id)
    assert first.status == :superseded
    assert second.status == :superseded
    assert second.next_step == "told_main"
    assert third.status == :open
    assert third.attempt == 3
    assert Offers.standing(id) == %{}

    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)

    refute_received {:agent_dispatch, ^main_id, _, _}
  end

  test "a delivery event arriving before the transport reply is retained", ctx do
    Application.put_env(
      :code_my_spec,
      :agent_transport,
      CodeMySpecTest.DeliveryBeforeAckTransport
    )

    assert {:ok, :queued, message} =
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

    assert :ok =
             Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
               "kind" => "message_delivered",
               "ref" => ref
             })

    assert :ok = Offers.settle_turn(ctx.agent)
    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :n_a
  end

  test "a delivered instruction is seen without judging the tools used", ctx do
    assert {:ok, :queued} = Agents.message_agent(ctx.scope, ctx.agent.id, "Inspect this.")
    assert_received {:agent_dispatch, _, ref, "Inspect this."}

    assert :ok =
             Agents.record_turn_event(ctx.scope, ctx.agent.id, %{
               "kind" => "message_delivered",
               "ref" => ref
             })

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

  test "a failed delivery is recorded without accusing the agent of ignoring it", ctx do
    Application.put_env(:code_my_spec, :agent_transport, CodeMySpecTest.UnreachableMachine)

    assert {:error, :harness_not_connected} =
             Agents.message_agent(ctx.scope, ctx.agent.id, "Inspect this.")

    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :undelivered
    assert [link] = offer.messages
    assert Repo.get!(Message, link.message_id).delivery == :failed
    assert :ok = Offers.settle_turn(ctx.agent)
    assert [settled] = Offers.list_for_agent(ctx.agent.id)
    assert settled.status == :undelivered
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

    assert :ok =
             Agents.record_turn_event(ctx.scope, id, %{
               "kind" => "message_delivered",
               "ref" => ref
             })

    assert Repo.get!(Message, message.id).delivery == :delivered

    assert :ok = Offers.settle_turn(ctx.agent)
    assert [settled] = Offers.list_for_agent(id)
    assert settled.status == :n_a
    assert settled.outcome_at
  end
end
