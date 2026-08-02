defmodule CodeMySpecSpex.Story965.Criterion7990Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7990 — Buying takes an explicit yes.

  Setup shows an available domain and its price and then *waits*. It does
  not register anything until Sam confirms. Registrations are
  non-refundable, so an automatic purchase on a name Sam merely typed is
  money he cannot get back.

  This is the one place in the whole epic where the routine deliberately
  stops and asks — everything else runs unattended.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @check_cassette "cloudflare_domain_check_new_name"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Buying takes an explicit yes" do
    scenario "checking a new name never registers it — the yes happens in the dashboard" do
      # Regrounded on what the Registrar API actually does. It will not price
      # or sell an arbitrary new name, so there is no in-app price to show and
      # no in-app purchase to confirm — the honest guarantee is stronger and
      # simpler: *setup never buys a domain by itself*. The explicit yes is
      # Sam registering it in the dashboard, which setup then adopts (8052).
      given_ "Sam checks a name he might want", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        html =
          with_provider_cassette(@check_cassette, fn ->
            view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
            |> render_submit()
          end)

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "he has done nothing but check it", context do
        # No confirmation, no dashboard trip — just the check. The absence of
        # any purchase is the condition under test.
        {:ok, context}
      end

      then_ "nothing is registered", context do
        refute context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected no registration from merely checking a name"

        refute has_element?(context.view, "[data-test='domain-registered']"),
               "expected the domain not to be claimed before Sam registered it himself"

        {:ok, context}
      end

      then_ "the yes is handed to the dashboard rather than taken in-app", context do
        # There is no in-app confirm button for a name the API cannot sell —
        # setup cannot buy it, so it does not pretend to. The explicit action
        # is the dashboard link, and setup holds rather than pressing on.
        assert has_element?(context.view, "[data-test='domain-dashboard-link']"),
               "expected the purchase to be handed to the dashboard"

        refute has_element?(context.view, "[data-test='setup-step'][data-state='running']"),
               "expected setup to hold rather than press on to later steps"

        {:ok, context}
      end
    end
  end
end
