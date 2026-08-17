defmodule CodeMySpecSpex.Story816.Criterion6594Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6594 — Sending from a mailbox delivers through the email provider.

  Rule: A project must have a verified domain before its mailboxes can
  send or receive email.

  Surface:
    * `CodeMySpecWeb.MailLive` at "/app/projects/:project_id/mail" — composing from a mailbox sends
      through the email provider and the message shows as Sent in the thread.
      The provider (Resend) send is replayed from a recorded response via
      `Req.Test` (shared mode); the "Sent" marker is driven by the provider's
      returned message id, so it only appears when delivery actually went
      through the provider.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpec.Mail.ResendClient

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  @domain "sam-ships.com"

  spex "Composing delivers through the provider and shows as Sent" do
    scenario "Sending from a mailbox delivers through the email provider" do
      given_ "a verified domain with a mailbox", context do
        Fixtures.verify_project_domain(context.project, @domain)
        Fixtures.mailbox_fixture(context.project, %{address: "support@#{@domain}"})

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mail")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam composes and sends an email from the mailbox", context do
        {:ok, show_view, _html} =
          context.view
          |> element("[data-test='mailbox']", "support@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        show_view
        |> form("[data-test='compose-form']",
          email: %{
            to: "lead@example.com",
            subject: "Welcome aboard",
            body: "Thanks for signing up!"
          }
        )
        |> render_submit()

        {:ok, Map.put(context, :show_view, show_view)}
      end

      then_ "the email is delivered through the provider and shown as Sent", context do
        html = render(context.show_view)

        assert html =~ "Welcome aboard",
               "expected the sent email to appear in the thread"

        assert html =~ "support@#{@domain}",
               "expected it sent from the mailbox address"

        assert has_element?(context.show_view, "[data-test='email-sent']"),
               "expected the email to be marked Sent once the provider accepted it"

        {:ok, context}
      end
    end
  end

  defp stub_resend(_context) do
    Req.Test.set_req_test_to_shared(%{})
    previous = Application.get_env(:code_my_spec, ResendClient, [])

    Application.put_env(:code_my_spec, ResendClient,
      api_key: "re_test",
      plug: {Req.Test, ResendClient}
    )

    on_exit(fn -> Application.put_env(:code_my_spec, ResendClient, previous) end)

    Req.Test.stub(ResendClient, fn conn ->
      body =
        case {conn.method, conn.request_path} do
          {"POST", "/emails"} -> cassette("send")
          _ -> cassette("send")
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  defp cassette(name), do: File.read!(Path.join(["test", "cassettes", "resend", "#{name}.json"]))
end
