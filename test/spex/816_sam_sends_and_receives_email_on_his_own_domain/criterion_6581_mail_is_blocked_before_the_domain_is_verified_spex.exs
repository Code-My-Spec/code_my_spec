defmodule CodeMySpecSpex.Story816.Criterion6581Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6581 — Mail is blocked before the domain is verified.

  Rule: A project must have a verified domain before its mailboxes can
  send or receive email.

  Surface:
    * `CodeMySpecWeb.MailLive` at "/app/mail" — when the project's domain is
      not yet verified, the mail inbox gates sending/receiving behind
      verification rather than letting mail flow.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "not-yet.com"

  spex "Mail is gated until the domain is verified" do
    scenario "Mail is blocked before the domain is verified" do
      given_ "the project has a domain that is not yet verified", context do
        Fixtures.set_project_domain(context.project, @domain)

        {:ok, Map.put(context, :domain, @domain)}
      end

      when_ "Sam opens the mail surface", context do
        {:ok, view, html} = live(context.conn, "/app/mail")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "he is told to verify the domain and cannot send", context do
        assert context.html =~ "verify" or context.html =~ "Verify",
               "expected a notice that the domain must be verified before mail flows"

        refute has_element?(context.view, "[data-test='compose-form']"),
               "expected no compose surface while the domain is unverified"

        {:ok, context}
      end
    end
  end
end
