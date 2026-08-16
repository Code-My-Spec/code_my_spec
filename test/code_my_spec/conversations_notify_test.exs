defmodule CodeMySpec.ConversationsNotifyTest do
  @moduledoc """
  Offline email fallback: a teammate's reply to a customer who isn't connected
  is emailed to them from the project's own mailbox (via `CodeMySpec.Mail`),
  and silently skips when the project has no mailbox.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Conversations, Mail}
  alias CodeMySpec.Mail.ResendClient

  setup do
    # Says what the provider does, rather than relying on it being
    # unconfigured. This test passed before because no Resend key was set, so
    # the send failed early and the record was written anyway — it asserts on
    # the record, and the provider was incidental. The key now comes from
    # `config/test.exs`, so the call is real and needs an answer.
    Req.Test.stub(ResendClient, fn conn ->
      Req.Test.json(conn, %{"id" => "email_offline_reply"})
    end)

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
