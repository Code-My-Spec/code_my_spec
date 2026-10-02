defmodule CodeMySpec.Conversations.ReadsTest do
  @moduledoc """
  Per-user read state: unseen messages make a chat unread, reading clears it,
  and the user's own toggle overrides either way.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Reads

  setup do
    scope = full_scope_fixture()

    {:ok, conversation} =
      Conversations.find_or_create_conversation(
        scope.active_account_id,
        scope.active_project_id,
        "enduser@example.com"
      )

    %{scope: scope, conversation: conversation}
  end

  defp unread?(scope, conversation),
    do: scope |> Reads.states([conversation.id]) |> Reads.unread?(conversation.id)

  test "a chat with no messages is read", %{scope: scope, conversation: conversation} do
    refute unread?(scope, conversation)
  end

  test "an unseen message makes it unread; reading clears it", ctx do
    {:ok, _} = Conversations.add_message(ctx.conversation, :user, "hello?")
    assert unread?(ctx.scope, ctx.conversation)

    {:ok, _} = Reads.set_read(ctx.scope, ctx.conversation.id, true)
    refute unread?(ctx.scope, ctx.conversation)

    {:ok, _} = Conversations.add_message(ctx.conversation, :user, "still there?")
    assert unread?(ctx.scope, ctx.conversation)
  end

  test "marking unread overrides until the next read", ctx do
    {:ok, _} = Conversations.add_message(ctx.conversation, :user, "hello?")
    {:ok, _} = Reads.set_read(ctx.scope, ctx.conversation.id, true)

    {:ok, _} = Reads.set_read(ctx.scope, ctx.conversation.id, false)
    assert unread?(ctx.scope, ctx.conversation)

    {:ok, _} = Reads.set_read(ctx.scope, ctx.conversation.id, true)
    refute unread?(ctx.scope, ctx.conversation)
  end

  test "a chat with no messages can still be marked unread", ctx do
    {:ok, _} = Reads.set_read(ctx.scope, ctx.conversation.id, false)
    assert unread?(ctx.scope, ctx.conversation)
  end

  test "read state is per user", ctx do
    {:ok, _} = Conversations.add_message(ctx.conversation, :user, "hello?")
    teammate = user_fixture()
    teammate_scope = %{ctx.scope | user: teammate, user_id: teammate.id}

    {:ok, _} = Reads.set_read(ctx.scope, ctx.conversation.id, true)

    refute unread?(ctx.scope, ctx.conversation)
    assert unread?(teammate_scope, ctx.conversation)
  end

  test "states carry the latest message time", ctx do
    {:ok, message} = Conversations.add_message(ctx.conversation, :user, "hello?")

    assert %{last_message_at: at} =
             Reads.states(ctx.scope, [ctx.conversation.id])[ctx.conversation.id]

    assert DateTime.compare(at, message.inserted_at) == :eq
  end

  test "another account's conversation is refused", ctx do
    other = full_scope_fixture()
    assert {:error, :not_found} = Reads.set_read(other, ctx.conversation.id, true)
    assert Reads.states(other, [ctx.conversation.id]) == %{}
  end
end
