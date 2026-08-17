defmodule CodeMySpecSpex.Story816.Criterion6593Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6593 — Verification fails until the DNS records are in place.

  Rule: A project must have a verified domain before its mailboxes can
  send or receive email.

  Surface:
    * `CodeMySpecWeb.ProjectLive.Form` at "/app/projects/:id/edit" (owner/admin)
      — if the operator verifies before the DNS records have propagated, the
      provider reports the domain unverified and mail stays gated. The provider
      (Resend) is replayed from recorded responses via `Req.Test` (shared mode).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  spex "Verifying before DNS is in place leaves the domain gated" do
    scenario "Verification fails until the DNS records are in place" do
      given_ "Sam has registered his sending domain but not published the records", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        view
        |> form("[data-test='add-domain-form']", project: %{domain: "sam-ships.com"})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam clicks Verify before the records have propagated", context do
        context.view
        |> element("[data-test='verify-domain']")
        |> render_click()

        {:ok, context}
      end

      then_ "the domain stays unverified and mail remains gated", context do
        html = render(context.view)

        assert html =~ "not verified yet",
               "expected a notice that the domain is still unverified"

        assert html =~ "Verify your sending domain",
               "expected mail to remain gated behind verification"

        {:ok, context}
      end
    end
  end

  defp stub_resend(_context), do: Fixtures.stub_resend_domain(:pending)
end
