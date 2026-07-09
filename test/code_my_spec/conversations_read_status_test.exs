defmodule CodeMySpec.ConversationsReadStatusTest do
  @moduledoc """
  Read/unread and open/closed lifecycle on the operator inbox: an end-user
  message marks a conversation unread; an operator message or opening it marks
  it read; conversations can be closed and reopened.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations

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

  test "a new conversation starts read", %{conversation: conversation} do
    assert conversation.read
    assert conversation.status == :open
  end

  test "an end-user message marks it unread; an operator message marks it read", ctx do
    {:ok, _} = Conversations.add_message(ctx.conversation, :user, "hello?")
    assert Conversations.unread_count(ctx.scope) == 1
    assert Conversations.get_conversation!(ctx.scope, ctx.conversation.id).read == false

    {:ok, _} = Conversations.add_message(ctx.conversation, :operator, "hi!", "1")
    assert Conversations.unread_count(ctx.scope) == 0
    assert Conversations.get_conversation!(ctx.scope, ctx.conversation.id).read == true
  end

  test "mark_read clears the unread flag and is idempotent", ctx do
    {:ok, _} = Conversations.add_message(ctx.conversation, :user, "still there?")
    assert Conversations.unread_count(ctx.scope) == 1

    {:ok, updated} = Conversations.mark_read(ctx.scope, ctx.conversation.id)
    assert updated.read
    assert Conversations.unread_count(ctx.scope) == 0

    {:ok, again} = Conversations.mark_read(ctx.scope, ctx.conversation.id)
    assert again.read
  end

  test "set_status closes and reopens a conversation", ctx do
    {:ok, closed} = Conversations.set_status(ctx.scope, ctx.conversation.id, :closed)
    assert closed.status == :closed

    {:ok, reopened} = Conversations.set_status(ctx.scope, ctx.conversation.id, :open)
    assert reopened.status == :open
  end
end
