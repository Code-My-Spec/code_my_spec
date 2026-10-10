defmodule CodeMySpec.Agents.Mailbox.AuthorityTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo

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
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, AcceptingTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
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

  test "busy leaves the only payload queued in the database", ctx do
    Application.put_env(:code_my_spec, :agent_transport, BusyTransport)
    {message, _} = admit(ctx, "first")
    assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
    assert [%{state: :queued}] = Mailbox.entries(ctx.scope, ctx.agent.id)
    assert Repo.get!(Conversations.Message, message.id).delivery == :pending
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

  test "confirmed engine replacement preserves interrupted evidence and releases later mail",
       ctx do
    {first, _} = admit(ctx, "interrupted")
    {second, _} = admit(ctx, "still waiting")
    Mailbox.pump(ctx.scope, ctx.agent.id)
    Mailbox.ready(ctx.scope, ctx.agent.id, "engine-one", nil)
    Mailbox.register(ctx.scope, ctx.agent.id, "replacement")
    Mailbox.ready(ctx.scope, ctx.agent.id, "replacement", nil)

    assert [%{state: :interrupted, delivery_ref: ref}, %{state: :queued}] =
             Mailbox.entries(ctx.scope, ctx.agent.id)

    assert ref == first.delivery_ref
    assert Repo.get!(Conversations.Message, second.id).delivery == :pending

    assert [%{mailbox_state: "interrupted"}, %{mailbox_state: "queued"}] =
             Mailbox.waiting_messages(ctx.conversation)
  end

  defmodule LostAckTransport do
    def dispatch_message(copy, agent, ref, text, timeout) do
      {:ok, :started} = AcceptingTransport.dispatch_message(copy, agent, ref, text, timeout)
      {:error, :message_timed_out}
    end
  end

  test "lost transport acknowledgement cannot obscure committed consumption", ctx do
    Application.put_env(:code_my_spec, :agent_transport, LostAckTransport)
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
