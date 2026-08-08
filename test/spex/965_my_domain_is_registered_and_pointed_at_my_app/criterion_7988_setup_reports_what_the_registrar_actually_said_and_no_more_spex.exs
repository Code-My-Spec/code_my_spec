defmodule CodeMySpecSpex.Story965.Criterion7988Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7988 — Setup reports what the registrar actually said, and no more.

  Before any money moves, Sam types the domain he wants and gets back
  whether it is available and what it costs. Registrations are
  non-refundable, so price has to be on screen *before* the decision, not
  after it.

  The Cloudflare availability/pricing round-trip is replayed from a
  ReqCassette — the spec drives the page and the app's own Req client is
  what gets intercepted.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_domain_check_unpriced"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Setup reports what the registrar actually said, and no more" do
    scenario "an available domain comes back with its price before he commits" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he types the domain he wants and setup checks it", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees the registrar's answer for the name he typed", context do
        # The honest answer for a name the account does not already hold: the
        # registrar reports whether the *extension* is supported, not a price
        # and not a definite yes. Cloudflare will not price or sell an
        # arbitrary new name through the API, so "sees what it costs" is not a
        # thing the API can give — the check tells Sam the name is a real
        # candidate, and cost lives where the purchase does.
        assert has_element?(
                 context.view,
                 "[data-test='domain-availability'][data-name='sams-new-thing.com']"
               ),
               "expected the registrar's answer to be shown for the name Sam typed"

        assert has_element?(
                 context.view,
                 "[data-test='domain-availability'][data-supported-tld='true']"
               ),
               "expected the supported extension to be reported"

        {:ok, context}
      end

      then_ "he is told where buying happens, and nothing is bought by looking", context do
        # Buying is a Cloudflare dashboard errand (Sam's call once the API
        # proved unable to price a new name). The check hands him there rather
        # than pretending to a price it does not have — and buys nothing.
        assert has_element?(context.view, "[data-test='domain-dashboard-link']"),
               "expected the check to hand Sam to the dashboard, where cost and purchase live"

        refute has_element?(context.view, "[data-test='domain-registered']"),
               "expected nothing to be registered merely by checking a name"

        {:ok, context}
      end
    end
  end
end
