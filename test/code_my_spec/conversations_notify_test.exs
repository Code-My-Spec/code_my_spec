defmodule CodeMySpec.ConversationsNotifyTest do
  @moduledoc """
  Offline email fallback: a teammate's reply to a customer who isn't connected
  is emailed to them from the project's own mailbox (via `CodeMySpec.Mail`),
  and silently skips when the project has no mailbox.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Conversations, Mail}

  setup do
    scope = full_scope_fixture()

    {:ok, conversation} =
      Conversations.find_or_create_conversation(
        scope.active_account_id,
        scope.active_project_id,
        "customer@example.com"
      )

    %{scope: scope, conversation: conversation}
  end

  test "emails the customer from the project's catch-all mailbox", ctx do
    {:ok, mailbox} =
      Mail.create_mailbox(ctx.scope, %{"address" => "support@proj.test", "catch_all" => true})

    assert :ok = Conversations.notify_offline_reply(ctx.conversation, "Here is your answer")

    assert [%{emails: [email]}] = Mail.list_threads(mailbox)
    assert email.direction == :outbound
    assert email.to_address == "customer@example.com"
    assert email.body_text =~ "Here is your answer"
  end

  test "skips silently when the project has no mailbox", ctx do
    assert :skip = Conversations.notify_offline_reply(ctx.conversation, "hello")
  end
end
