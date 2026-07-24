defmodule CodeMySpecSpex.Story816.Criterion6592Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6592 — Verifying the domain unlocks mail.

  Rule: A project must have a verified domain before its mailboxes can
  send or receive email.

  Surface:
    * `CodeMySpecWeb.ProjectLive.Form` at "/app/projects/:id/edit" (owner/admin)
      — once the DNS records are in place, clicking Verify marks the domain
      verified and enables mail. The provider (Resend) is replayed from recorded
      responses via `Req.Test` (shared mode).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Mail.ResendClient

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  spex "Verifying a domain whose DNS is in place enables mail" do
    scenario "Verifying the domain unlocks mail" do
      given_ "Sam has registered his sending domain", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        view
        |> form("[data-test='add-domain-form']", project: %{domain: "sam-ships.com"})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam verifies the domain after publishing the records", context do
        context.view
        |> element("[data-test='verify-domain']")
        |> render_click()

        {:ok, context}
      end

      then_ "the domain is verified and mail is enabled", context do
        html = render(context.view)

        assert html =~ "mail is now enabled",
               "expected confirmation that verifying the domain enabled mail"

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
          {"POST", "/domains"} -> cassette("domain_create")
          {"POST", "/domains/" <> _} -> cassette("verify_trigger")
          {"GET", "/domains/" <> _} -> cassette("domain_verified")
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  defp cassette(name), do: File.read!(Path.join(["test", "cassettes", "resend", "#{name}.json"]))
end
