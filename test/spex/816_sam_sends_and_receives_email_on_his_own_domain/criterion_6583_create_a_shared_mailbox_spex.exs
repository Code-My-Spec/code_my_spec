defmodule CodeMySpecSpex.Story816.Criterion6583Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6583 — Create a shared mailbox.

  Rule: Sam can create mailboxes on a project, each assigned to a user
  or shared with no user.

  Surface (forward-looking — red until built):
    * `CodeMySpecWeb.MailboxLive` at "/app/mailboxes" — submitting the
      new-mailbox form with no assigned user creates a shared mailbox.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "Sam creates a shared mailbox" do
    scenario "Create a shared mailbox" do
      given_ "the domain is verified", context do
        Fixtures.verify_project_domain(context.project, @domain)

        {:ok, view, _html} = live(context.conn, "/app/mailboxes")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam creates a mailbox with no assigned user", context do
        context.view
        |> form("[data-test='new-mailbox-form']", mailbox: %{address: "hello@#{@domain}", user_id: ""})
        |> render_submit()

        {:ok, context}
      end

      then_ "a shared mailbox appears", context do
        html = render(context.view)

        assert html =~ "hello@#{@domain}",
               "expected the new shared mailbox to be listed"

        assert html =~ "Shared" or html =~ "shared",
               "expected the mailbox to be marked shared (no assigned user)"

        {:ok, context}
      end
    end
  end
end
