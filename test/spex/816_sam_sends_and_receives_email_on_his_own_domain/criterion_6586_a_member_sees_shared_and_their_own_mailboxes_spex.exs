defmodule CodeMySpecSpex.Story816.Criterion6586Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6586 — A member sees shared and their own mailboxes.

  Rule: A member sees the project's shared mailboxes plus any mailbox
  assigned to them.

  Surface:
    * `CodeMySpecWeb.MailLive` at "/app/mail" — the inbox sidebar is scoped to
      the current member: shared mailboxes plus the member's own assigned
      mailbox, never another member's assigned mailbox.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "A member's mail view is scoped to shared plus their own" do
    scenario "A member sees shared and their own mailboxes" do
      given_ "a shared mailbox and one mailbox assigned to each of two members", context do
        Fixtures.verify_project_domain(context.project, @domain)

        alice = Fixtures.user_fixture()
        _alice_member = Fixtures.member_fixture(alice, context.account, :member)
        bob = Fixtures.user_fixture()
        _bob_member = Fixtures.member_fixture(bob, context.account, :member)

        Fixtures.mailbox_fixture(context.project, %{address: "team@#{@domain}"})
        Fixtures.mailbox_fixture(context.project, %{address: "alice@#{@domain}", user_id: alice.id})
        Fixtures.mailbox_fixture(context.project, %{address: "bob@#{@domain}", user_id: bob.id})

        alice_scope = Fixtures.user_scope_fixture(alice, context.account)
        Fixtures.select_active_account(alice_scope, context.account.id)
        alice_conn = log_in_user(build_conn(), alice)

        {:ok, Map.put(context, :alice_conn, alice_conn)}
      end

      when_ "the member opens the mail surface", context do
        {:ok, _view, html} = live(context.alice_conn, "/app/mail")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "she sees the shared and her own mailbox but not the other member's", context do
        assert context.html =~ "team@#{@domain}",
               "expected the member to see the shared mailbox"

        assert context.html =~ "alice@#{@domain}",
               "expected the member to see her own assigned mailbox"

        refute context.html =~ "bob@#{@domain}",
               "expected the member NOT to see another member's assigned mailbox"

        {:ok, context}
      end
    end
  end
end
