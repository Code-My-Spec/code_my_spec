defmodule CodeMySpecSpex.Story816.Criterion6589Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6589 — Replies thread with the original.

  Rule: A correspondent's emails form one continuous thread within a mailbox.

  Surfaces (forward-looking — red until built):
    * Inbound webhook "/webhooks/resend" delivers two emails from the same
      correspondent to the same mailbox.
    * `CodeMySpecWeb.MailboxLive` at "/app/mailboxes" — both show in one
      per-correspondent thread.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "A correspondent's emails form one thread" do
    scenario "Replies thread with the original" do
      given_ "an inbound email from a correspondent in the support mailbox", context do
        Fixtures.verify_project_domain(context.project, @domain)

        {:ok, view, _html} = live(context.conn, "/app/mailboxes")

        view
        |> form("[data-test='new-mailbox-form']", mailbox: %{address: "support@#{@domain}"})
        |> render_submit()

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/webhooks/resend", %{
          "type" => "email.received",
          "data" => %{
            "from" => "lead@example.com",
            "to" => ["support@#{@domain}"],
            "subject" => "First question",
            "text" => "What are your hours?",
            "message_id" => "<msg-6589-a@example.com>"
          }
        })

        {:ok, context}
      end

      when_ "the same correspondent sends a follow-up", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/webhooks/resend", %{
          "type" => "email.received",
          "data" => %{
            "from" => "lead@example.com",
            "to" => ["support@#{@domain}"],
            "subject" => "Re: First question",
            "text" => "Also, do you offer trials?",
            "message_id" => "<msg-6589-b@example.com>",
            "in_reply_to" => "<msg-6589-a@example.com>"
          }
        })

        {:ok, context}
      end

      then_ "both messages appear in one continuous thread", context do
        {:ok, view, _html} = live(context.conn, "/app/mailboxes")

        {:ok, _show_view, thread_html} =
          view
          |> element("[data-test='mailbox']", "support@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        assert thread_html =~ "What are your hours?",
               "expected the original message in the correspondent's thread"

        assert thread_html =~ "do you offer trials?",
               "expected the follow-up in the same thread as the original"

        {:ok, context}
      end
    end
  end
end
