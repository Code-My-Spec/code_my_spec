defmodule CodeMySpec.Agents.AMessageTheHarnessNeverHadIsTakenBackTest do
  @moduledoc """
  Issue 5150cd98: messages queued before a harness restart sat "waiting for the
  agent to finish its turn" for hours, and Take it back answered "Too late".
  The restart had dropped the queue, so nobody had them and nobody would
  deliver them. A message the harness never had is taken back; one it gave the
  agent is still refused.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Repo

  defmodule Answering do
    @moduledoc false
    def withdraw_message(_copy, _agent, _ref, _timeout),
      do: :persistent_term.get({__MODULE__, :answer})
  end

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, Answering)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    scope = full_scope_fixture()

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
        working_copy: "/tmp/never-had-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        scope.active_account_id,
        scope.active_project_id,
        "alloy:#{agent.id}"
      )

    ref = Ecto.UUID.generate()

    {:ok, message} =
      Conversations.add_message(conversation, :operator, "take this back", "operator", [],
        delivery: :pending,
        delivery_ref: ref
      )

    %{scope: scope, agent: agent, message: message, ref: ref}
  end

  defp answer(value), do: :persistent_term.put({Answering, :answer}, value)

  test "one the harness never had is withdrawn", ctx do
    answer({:error, :never_received})

    assert {:ok, %{delivery: :withdrawn}} =
             Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.ref)

    assert Repo.reload!(ctx.message).delivery == :withdrawn
  end

  test "one the agent was given is still too late", ctx do
    answer({:error, :already_delivered})

    assert {:error, :already_delivered} =
             Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.ref)

    assert Repo.reload!(ctx.message).delivery == :delivered
  end

  test "unreachable and uncertain outcomes remain pending", ctx do
    for reason <- [:not_running, :harness_not_connected, :message_timed_out] do
      answer({:error, reason})
      assert {:error, ^reason} = Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.ref)
      assert Repo.reload!(ctx.message).delivery == :pending
    end
  end

  test "successful withdrawal is recorded as withdrawn", ctx do
    answer(:ok)
    assert {:ok, %{delivery: :withdrawn}} =
             Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.ref)
    assert Repo.reload!(ctx.message).delivery == :withdrawn
  end

  test "authoritative consumption broadcasts and clears pending controls", ctx do
    topic = Conversations.conversation_topic(ctx.message.conversation_id)
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic)
    answer({:error, :already_delivered})
    assert {:error, :already_delivered} =
             Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.ref)
    assert_receive {:message_updated, %{id: id, delivery: :delivered}}
    assert id == ctx.message.id
    conversation = Repo.get!(Conversation, ctx.message.conversation_id)
    assert Conversations.pending_messages(conversation) == []
  end
end
