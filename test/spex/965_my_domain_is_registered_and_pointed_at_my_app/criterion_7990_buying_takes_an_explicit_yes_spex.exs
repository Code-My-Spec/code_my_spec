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

  @check_cassette "cloudflare_domain_check_available_with_price"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Buying takes an explicit yes" do
    scenario "an available, priced domain is not registered until Sam confirms" do
      given_ "Sam has been shown an available domain and its price", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@check_cassette, [mode: :replay], fn ->
          view
          |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
          |> render_submit()
        end)

        html = render(view)

        assert has_element?(view, "[data-test='domain-price']"),
               "expected the price to be on screen before the confirmation gate"

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "he has not confirmed the purchase", context do
        # Deliberately no click. The absence of the confirmation is the
        # condition under test.
        {:ok, context}
      end

      then_ "setup does not register it", context do
        refute context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected no registration without an explicit confirmation"

        refute has_element?(context.view, "[data-test='domain-registered']"),
               "expected the domain not to be registered before Sam said yes"

        {:ok, context}
      end

      then_ "it waits on him rather than proceeding", context do
        assert has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected setup to offer a confirmation and wait for it"

        refute has_element?(context.view, "[data-test='setup-step'][data-state='running']"),
               "expected setup to hold rather than press on to later steps"

        {:ok, context}
      end
    end
  end
end
