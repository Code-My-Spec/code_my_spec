defmodule CodeMySpecSpex.Story816.Criterion6582Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6582 — Create a mailbox assigned to a user.

  Rule: Sam can create mailboxes on a project, each assigned to a user
  or shared with no user.

  Surface (forward-looking — red until built):
    * `CodeMySpecWeb.MailboxLive` at "/app/projects/:project_id/mailboxes" — the new-mailbox form
      accepts an address and an optional assigned user; submitting with a
      user creates a mailbox owned by that user.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "Sam creates a mailbox assigned to a teammate" do
    scenario "Create a mailbox assigned to a user" do
      given_ "the domain is verified and a teammate is in the account", context do
        Fixtures.verify_project_domain(context.project, @domain)

        teammate = Fixtures.user_fixture()
        _member = Fixtures.member_fixture(teammate, context.account, :member)

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mailboxes")

        {:ok, Map.merge(context, %{view: view, teammate: teammate})}
      end

      when_ "Sam creates a mailbox assigned to the teammate", context do
        context.view
        |> form("[data-test='new-mailbox-form']",
          mailbox: %{address: "alice@#{@domain}", user_id: context.teammate.id}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the mailbox appears assigned to that teammate", context do
        html = render(context.view)

        assert html =~ "alice@#{@domain}",
               "expected the new mailbox to be listed"

        assert html =~ context.teammate.email,
               "expected the mailbox to show its assigned teammate"

        {:ok, context}
      end
    end
  end
end
