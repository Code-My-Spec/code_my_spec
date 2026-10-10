defmodule CodeMySpec.Agents.UnknownDeliveryTest do
  @moduledoc "Historical messages without a mailbox entry do not authorize delivery transitions."
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo

  setup do
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

  test "a message without mailbox ownership cannot be withdrawn", ctx do
    assert {:error, :not_pending} = Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.ref)
    assert Repo.reload!(ctx.message).delivery == :pending
  end
end
