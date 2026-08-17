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

  alias CodeMySpecSpex.Fixtures

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

  defp stub_resend(_context), do: Fixtures.stub_resend_domain(:verified)
end
