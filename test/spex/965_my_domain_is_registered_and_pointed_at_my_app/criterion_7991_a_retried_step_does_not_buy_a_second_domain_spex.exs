defmodule CodeMySpecSpex.Story965.Criterion7991Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7991 — A retried step does not buy a second domain.

  Idempotence with money attached. Once Sam owns the domain, re-running
  the domain step recognises that and charges nothing — no second
  registration, no second invoice. Every other step converging is a
  tidiness property; this one is the difference between a re-run and a
  bill.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A retried step does not buy a second domain" do
    scenario "re-running the domain step recognises the domain is already owned" do
      # Regrounded on adoption. Buying a new name is a dashboard errand, so
      # "does not buy a second domain" is really "re-running adopts the same
      # owned domain rather than acting twice". astralbi.com is a real zone the
      # account manages.
      given_ "setup already adopted the domain Sam owns", context do
        # Mounted before the domain is set. `ProvisioningLive.load/2` reads the
        # mail panel at mount whenever the project has a domain, and that read
        # calls Resend — while the mount sits outside every cassette, because
        # the idiom here is mount, then act under one. So a domain set first
        # puts a provider call in the one place no recording covers, and the
        # run dies in `mount/3` with `cannot find mock/stub`, which reads as a
        # `Req.Test` process-scoping problem rather than an uncovered call.
        # The zone, in the account. Under a cassette this was true because
        # John's Cloudflare really manages it; stated here, so the criterion
        # does not depend on whose account is recording.
        zone_exists(context, "astralbi.com")

        view = mount_provisioning(context)
        own_domain(context.project, "astralbi.com")

        view
        |> form("[data-test='domain-form']", domain: %{name: "astralbi.com"})
        |> render_submit()

        assert render(view) =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected adopting the owned domain to complete the step"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs again", context do
        context.view
        |> element("[data-test='setup-step'][data-step='domain'] [data-test='run-step']")
        |> render_click()

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup recognises he already owns it", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected the repeated run to settle as done"

        assert has_element?(
                 context.view,
                 "[data-test='domain-registered'][data-owned-already='true']"
               ),
               "expected setup to record that the domain was already owned rather than newly bought"

        {:ok, context}
      end

      then_ "it does not register or charge a second time", context do
        registrations =
          context.html
          |> Floki.parse_document!()
          |> Floki.find(
            "[data-test='setup-step'][data-step='domain'] " <>
              "[data-test='provisioned-resource'][data-kind='domain']"
          )

        assert length(registrations) == 1,
               "expected exactly one domain registration after two runs, got #{length(registrations)}"

        refute has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected no second purchase confirmation to be offered"

        {:ok, context}
      end
    end
  end
end
