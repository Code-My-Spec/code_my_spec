defmodule CodeMySpecSpex.Story816.Criterion6595Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6595 — A member cannot administer mailboxes.

  Rule: Account owners and admins create and administer the project's
  mailboxes; members use them but cannot administer them.

  Surface:
    * `CodeMySpecWeb.MailboxLive` at "/app/mailboxes" is owner/admin-only. A
      plain member is redirected to the Mail inbox ("/app/mail") rather than
      being shown the administration surface.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Mailbox administration is owner/admin only" do
    scenario "A member cannot administer mailboxes" do
      given_ "a plain member of the account", context do
        member = Fixtures.user_fixture()
        Fixtures.member_fixture(member, context.account, :member)

        member_scope = Fixtures.user_scope_fixture(member, context.account)
        Fixtures.select_active_account(member_scope, context.account.id)
        member_conn = log_in_user(build_conn(), member)

        {:ok, Map.put(context, :member_conn, member_conn)}
      end

      when_ "the member opens the mailbox administration surface", context do
        result = live(context.member_conn, "/app/mailboxes")

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the member is redirected to the mail inbox", context do
        assert {:error, {kind, %{to: "/app/mail"}}} = context.result,
               "expected the member to be redirected to the mail inbox, got: #{inspect(context.result)}"

        assert kind in [:redirect, :live_redirect]

        {:ok, context}
      end
    end
  end
end
