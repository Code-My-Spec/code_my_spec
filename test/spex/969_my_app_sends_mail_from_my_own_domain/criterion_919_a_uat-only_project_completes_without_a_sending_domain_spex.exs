defmodule CodeMySpecSpex.Story969.Criterion919Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain.
  Criterion 919 — A UAT-only project completes without a sending domain.

  Drives the console's email step with production disabled. No sending
  domain, DNS records, verification, or completed step is seeded.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_uat_only
  setup :fake_providers

  spex "A UAT-only project completes without a sending domain", criterion: 919 do
    scenario "the email step finishes without setting up mail for UAT" do
      given_ "a project with only UAT and no production environment", context do
        zone_exists(context, "astralbi.com")
        project = own_domain(context.project, "c919.astralbi.com")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{project.id}/console/resources/mail")

        {:ok, Map.merge(context, %{project: project, view: view})}
      end

      when_ "Sam runs the email step", context do
        run_console_step(context.view, :email)
        await_console_step(context.view, :email)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the step reports done even though UAT has no sending domain", context do
        parsed = Floki.parse_document!(context.html)

        assert Floki.find(
                 parsed,
                 "[data-test='resource-step'][data-step='email'][data-state='done']"
               ) != [],
               "expected the UAT-only email step to finish successfully"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "it registers, publishes, and verifies nothing", context do
        assert CodeMySpecSpex.Fixtures.resend_requests(fake(context, :resend)) == [],
               "expected no Resend requests for a UAT-only project"

        assert Floki.find(context.parsed, "[data-test='mail-sending-domain']") == [],
               "expected no sending domain for a UAT-only project"

        assert Floki.find(context.parsed, "[data-test='mail-dns-record']") == [],
               "expected the email step to publish no DNS records"

        assert Floki.find(context.parsed, "[data-test='mail-verification']") == [],
               "expected the email step to perform no domain verification"

        {:ok, context}
      end
    end
  end
end
