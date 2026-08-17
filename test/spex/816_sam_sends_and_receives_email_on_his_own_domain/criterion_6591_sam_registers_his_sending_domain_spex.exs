defmodule CodeMySpecSpex.Story816.Criterion6591Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6591 — Sam registers his sending domain.

  Rule: A project must have a verified domain before its mailboxes can
  send or receive email.

  Surface:
    * `CodeMySpecWeb.ProjectLive.Form` at "/app/projects/:id/edit" (owner/admin)
      — submitting the add-domain form registers the domain with the provider
      and shows the DNS records to publish. The provider (Resend) is replayed
      from a recorded response via `Req.Test` (shared mode, since the LiveView
      runs in its own process).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  spex "Registering a domain shows the DNS records to publish" do
    scenario "Sam registers his sending domain" do
      given_ "Sam is on his project settings with no domain set", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam submits his sending domain", context do
        context.view
        |> form("[data-test='add-domain-form']", project: %{domain: "sam-ships.com"})
        |> render_submit()

        {:ok, context}
      end

      then_ "the domain is registered and its DNS records are shown", context do
        html = render(context.view)

        assert html =~ "sam-ships.com",
               "expected the registered domain to be shown"

        assert html =~ "resend._domainkey",
               "expected the DKIM DNS record to be listed for the operator to publish"

        {:ok, context}
      end
    end
  end

  defp stub_resend(_context), do: Fixtures.stub_resend_domain(:not_started)
end
