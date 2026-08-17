defmodule CodeMySpecSpex.Story816.Criterion6588Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6588 — Reply From is the mailbox address.

  Rule: Replying from a mailbox sends with that mailbox's address as the From.

  Surfaces (forward-looking — red until built):
    * Inbound webhook "/webhooks/resend" seeds a received email.
    * `CodeMySpecWeb.MailLive` at "/app/projects/:project_id/mail" — replying from the mailbox
      sends with the mailbox address as the From.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  @domain "sam-ships.com"

  spex "Replying uses the mailbox address as From" do
    scenario "Reply From is the mailbox address" do
      given_ "an email received in the support mailbox", context do
        Fixtures.verify_project_domain(context.project, @domain)
        Fixtures.mailbox_fixture(context.project, %{address: "support@#{@domain}"})

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/webhooks/resend", %{
          "type" => "email.received",
          "data" => %{
            "from" => "lead@example.com",
            "to" => ["support@#{@domain}"],
            "subject" => "Need help",
            "text" => "Can you assist?",
            "message_id" => "<msg-6588@example.com>"
          }
        })

        {:ok, context}
      end

      when_ "Sam replies from the support mailbox", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mail")

        {:ok, show_view, _html} =
          view
          |> element("[data-test='mailbox']", "support@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        # Open the conversation, then reply from within it.
        show_view |> element("[data-test='thread']") |> render_click()

        show_view
        |> form("[data-test='reply-form']", email: %{body: "Happy to help — what's up?"})
        |> render_submit()

        {:ok, Map.put(context, :show_view, show_view)}
      end

      then_ "the reply is sent from the mailbox address", context do
        html = render(context.show_view)

        assert html =~ "Happy to help",
               "expected the reply to appear in the thread"

        assert html =~ "support@#{@domain}",
               "expected the reply's From to be the mailbox address"

        {:ok, context}
      end
    end
  end

  # The same stub its siblings use. `Mail.deliver/3` runs inside the LiveView
  # process, and a `Req.Test` stub is scoped to the process that set it, so
  # shared mode is what lets the LiveView see it.
  defp stub_resend(_context), do: Fixtures.stub_resend_send()
end
