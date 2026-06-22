defmodule CodeMySpecSpex.Story816.Criterion6585Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6585 — Unmatched inbound lands in the catch-all.

  Rule: Email sent to an address with no matching mailbox lands in the
  project's catch-all mailbox.

  Surfaces (forward-looking — red until built):
    * Inbound provider webhook at "/webhooks/resend" — an `email.received`
      event addressed to an address with no specific mailbox is routed to the
      project's catch-all mailbox.
    * `CodeMySpecWeb.MailLive` at "/app/mail".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "Unmatched inbound falls through to the catch-all" do
    scenario "Unmatched inbound lands in the catch-all" do
      given_ "a catch-all mailbox and no mailbox for the target address", context do
        Fixtures.verify_project_domain(context.project, @domain)
        Fixtures.mailbox_fixture(context.project, %{address: "inbox@#{@domain}", catch_all: true})

        {:ok, context}
      end

      when_ "an email arrives to an address with no specific mailbox", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/webhooks/resend", %{
          "type" => "email.received",
          "data" => %{
            "from" => "stranger@example.com",
            "to" => ["random#{System.unique_integer([:positive])}@#{@domain}"],
            "subject" => "Hello there",
            "text" => "Is anyone home?",
            "message_id" => "<msg-6585@example.com>"
          }
        })

        {:ok, context}
      end

      then_ "the email appears in the catch-all mailbox", context do
        {:ok, view, _html} = live(context.conn, "/app/mail")

        {:ok, _show_view, thread_html} =
          view
          |> element("[data-test='mailbox']", "inbox@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        assert thread_html =~ "Hello there",
               "expected the unmatched email to land in the catch-all mailbox"

        {:ok, context}
      end
    end
  end
end
