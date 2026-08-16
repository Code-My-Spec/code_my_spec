defmodule CodeMySpecSpex.Story816.Criterion6580Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6580 — Mail flows once the domain is verified.

  Rule: A project must have a verified domain before its mailboxes can
  send or receive email.

  Surface:
    * `CodeMySpecWeb.MailLive` at "/app/projects/:project_id/mail" — the operator's mail inbox.
      With a verified project domain and a mailbox, composing and sending
      delivers the email from the mailbox address.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Mail.ResendClient
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  @domain "sam-ships.com"

  spex "A mailbox on a verified domain can send" do
    scenario "Mail flows once the domain is verified" do
      given_ "the project's domain is verified and a mailbox exists", context do
        Fixtures.verify_project_domain(context.project, @domain)
        Fixtures.mailbox_fixture(context.project, %{address: "support@#{@domain}"})

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mail")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam opens the mailbox and sends an email", context do
        {:ok, show_view, _html} =
          context.view
          |> element("[data-test='mailbox']", "support@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        show_view
        |> form("[data-test='compose-form']",
          email: %{to: "lead@example.com", subject: "Welcome aboard", body: "Thanks for signing up!"}
        )
        |> render_submit()

        {:ok, Map.put(context, :show_view, show_view)}
      end

      then_ "the email is delivered from the mailbox", context do
        html = render(context.show_view)

        assert html =~ "Welcome aboard",
               "expected the sent email to appear in the mailbox thread"

        assert html =~ "support@#{@domain}",
               "expected the email to be sent from the mailbox address"

        {:ok, context}
      end
    end
  end

  # The same stub its five siblings use, and the reason it is needed here is
  # the reason it is needed there: `Mail.deliver/3` runs inside the LiveView
  # process, and a `Req.Test` stub is scoped to the process that set it. Shared
  # mode is what lets the LiveView see it.
  #
  # Without it the run dies with `cannot find mock/stub
  # CodeMySpec.Mail.ResendClient in process #PID<…>` — which names process
  # scoping, and is for once exactly right about the cause.
  defp stub_resend(_context) do
    Req.Test.set_req_test_to_shared(%{})
    previous = Application.get_env(:code_my_spec, ResendClient, [])

    Application.put_env(:code_my_spec, ResendClient,
      api_key: "re_test",
      plug: {Req.Test, ResendClient}
    )

    on_exit(fn -> Application.put_env(:code_my_spec, ResendClient, previous) end)

    Req.Test.stub(ResendClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, resend_cassette("send"))
    end)

    :ok
  end
end
