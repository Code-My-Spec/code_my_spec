defmodule CodeMySpec.Agents.Mailbox.AMessageSentNowEntersTheRunningTurnTest do
  @moduledoc """
  Story 1051: a message sent now is taken at the running turn's next tool
  boundary; everything else waits for the turn to end.
  """
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo

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

  defp admit(ctx, text, opts \\ []) do
    {:ok, message} =
      Conversations.add_message(ctx.conversation, :operator, text, "operator", [],
        delivery: :pending,
        delivery_ref: Ecto.UUID.generate()
      )

    Mailbox.admit(ctx.agent, message, :operator_message, opts)
    message
  end

  # The agent takes `text` and is mid-turn on it.
  defp busy(ctx, text) do
    message = admit(ctx, text)
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)
    message
  end

  defp state_of(message), do: Repo.get_by!(Mailbox.Entry, message_id: message.id).state
  defp delivery_of(message), do: Repo.get!(Conversations.Message, message.id).delivery

  test "the running turn takes what was sent now, and only that", ctx do
    turn = busy(ctx, "build the chart")
    later = admit(ctx, "after this, the docs")
    now = admit(ctx, "stop and merge main", send_now: true)

    assert {:ok, ["stop and merge main"]} =
             Mailbox.take_send_now(ctx.scope, ctx.agent.id, "engine-one")

    assert state_of(now) == :completed
    assert delivery_of(now) == :delivered
    assert state_of(turn) == :consumed
    assert state_of(later) == :queued
    assert {:ok, []} = Mailbox.take_send_now(ctx.scope, ctx.agent.id, "engine-one")
  end

  test "an engine with no turn, or not the current one, takes nothing", ctx do
    assert {:error, :no_turn} = Mailbox.take_send_now(ctx.scope, ctx.agent.id, "engine-one")

    busy(ctx, "build the chart")
    now = admit(ctx, "stop", send_now: true)
    assert {:error, :stale_engine} = Mailbox.take_send_now(ctx.scope, ctx.agent.id, "old-engine")
    assert state_of(now) == :queued
  end

  test "a message sent now that no tool boundary took goes ahead when the turn ends", ctx do
    turn = busy(ctx, "build the chart")
    later = admit(ctx, "after this, the docs")
    now = admit(ctx, "stop and merge main", send_now: true)

    {:ok, _} = Mailbox.finish(ctx.scope, ctx.agent.id, turn.delivery_ref, "engine-one")
    assert {:ok, :started} = Mailbox.pump(ctx.scope, ctx.agent.id)

    assert state_of(now) == :consumed
    assert state_of(later) == :queued
  end

  test "a queued message can be sent now until the agent has it", ctx do
    busy(ctx, "build the chart")
    later = admit(ctx, "stop and merge main")

    assert {:ok, %{send_now: true}} =
             Mailbox.send_now(ctx.scope, ctx.agent.id, later.delivery_ref)

    assert {:ok, ["stop and merge main"]} =
             Mailbox.take_send_now(ctx.scope, ctx.agent.id, "engine-one")

    assert {:error, :already_delivered} =
             Mailbox.send_now(ctx.scope, ctx.agent.id, later.delivery_ref)
  end

  test "a message sent now can be withdrawn until the turn takes it", ctx do
    busy(ctx, "build the chart")
    now = admit(ctx, "stop", send_now: true)

    assert {:ok, _} = Mailbox.withdraw(ctx.scope, ctx.agent.id, now.delivery_ref)
    assert {:ok, []} = Mailbox.take_send_now(ctx.scope, ctx.agent.id, "engine-one")
    assert delivery_of(now) == :withdrawn
  end
end
