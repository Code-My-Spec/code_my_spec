defmodule CodeMySpecSpex.Story816.Criterion6584Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6584 — Inbound email routes to its mailbox.

  Rule: Email sent to a mailbox's address appears in that mailbox.

  Surfaces (forward-looking — red until built):
    * Inbound provider webhook at "/webhooks/resend" — an `email.received`
      event is routed by its To-address to the matching mailbox and persisted.
    * `CodeMySpecWeb.MailLive` at "/app/projects/:project_id/mail" — the operator opens the
      mailbox and sees the received email.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "Inbound email lands in the matching mailbox" do
    scenario "Inbound email routes to its mailbox" do
      given_ "a verified domain with a support mailbox", context do
        Fixtures.verify_project_domain(context.project, @domain)
        Fixtures.mailbox_fixture(context.project, %{address: "support@#{@domain}"})

        {:ok, context}
      end

      when_ "an email arrives addressed to the support mailbox", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/webhooks/resend", %{
          "type" => "email.received",
          "data" => %{
            "from" => "lead@example.com",
            "to" => ["support@#{@domain}"],
            "subject" => "Question about pricing",
            "text" => "How much does this cost?",
            "message_id" => "<msg-6584@example.com>"
          }
        })

        {:ok, context}
      end

      then_ "the email appears in the support mailbox", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mail")

        {:ok, _show_view, thread_html} =
          view
          |> element("[data-test='mailbox']", "support@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        assert thread_html =~ "Question about pricing",
               "expected the inbound email to appear in the support mailbox"

        {:ok, context}
      end
    end
  end
end
