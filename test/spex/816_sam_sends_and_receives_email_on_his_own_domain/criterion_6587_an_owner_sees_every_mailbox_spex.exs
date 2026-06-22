defmodule CodeMySpecSpex.Story816.Criterion6587Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6587 — An owner sees every mailbox.

  Rule: Account owners and admins see all of the project's mailboxes.

  Surface (forward-looking — red until built):
    * `CodeMySpecWeb.MailboxLive` at "/app/mailboxes" — for an account owner,
      the list shows every mailbox regardless of assignment.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "An owner sees every mailbox in the project" do
    scenario "An owner sees every mailbox" do
      given_ "shared and member-assigned mailboxes exist", context do
        Fixtures.verify_project_domain(context.project, @domain)

        alice = Fixtures.user_fixture()
        _alice_member = Fixtures.member_fixture(alice, context.account, :member)
        bob = Fixtures.user_fixture()
        _bob_member = Fixtures.member_fixture(bob, context.account, :member)

        Fixtures.mailbox_fixture(context.project, %{address: "team@#{@domain}"})
        Fixtures.mailbox_fixture(context.project, %{address: "alice@#{@domain}", user_id: alice.id})
        Fixtures.mailbox_fixture(context.project, %{address: "bob@#{@domain}", user_id: bob.id})

        {:ok, context}
      end

      when_ "the account owner opens the mail surface", context do
        {:ok, _view, html} = live(context.conn, "/app/mailboxes")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the owner sees all of the mailboxes", context do
        assert context.html =~ "team@#{@domain}",
               "expected the owner to see the shared mailbox"

        assert context.html =~ "alice@#{@domain}",
               "expected the owner to see a member's assigned mailbox"

        assert context.html =~ "bob@#{@domain}",
               "expected the owner to see every member's assigned mailbox"

        {:ok, context}
      end
    end
  end
end
