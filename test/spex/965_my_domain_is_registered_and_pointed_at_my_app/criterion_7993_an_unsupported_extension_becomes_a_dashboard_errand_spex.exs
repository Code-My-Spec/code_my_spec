defmodule CodeMySpecSpex.Story965.Criterion7993Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7993 — An unsupported extension becomes a dashboard errand.

  Only a subset of Cloudflare Registrar TLDs are available through the
  beta API. When Sam's extension is outside it, setup does not fail — it
  hands him a dashboard errand, then adopts the domain when he returns
  having done it. The API limit becomes a detour rather than a wall.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @unsupported_cassette "965_7993_cloudflare_tld_not_available_via_api"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "An unsupported extension becomes a dashboard errand" do
    scenario "an out-of-beta TLD is handed off and then adopted on return" do
      given_ "Sam wants a domain whose extension the API cannot sell", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      # `.museum` rather than `.io` — the original assumed `.io` was
      # unsupported, but the Registrar API sells it. `.museum` genuinely
      # returns `supported_tld: false`, which is the case under test.
      when_ "Sam checks a name whose extension the Registrar API cannot sell", context do
        html =
          with_provider_cassette(@unsupported_cassette, fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.museum"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup names it a dashboard errand rather than failing", context do
        parsed = Floki.parse_document!(context.html)

        handoff = Floki.find(parsed, "[data-test='domain-unsupported']") |> Floki.text()

        assert handoff =~ ~r/dashboard/i,
               "expected an unsupported extension to be named a dashboard errand, got: #{inspect(handoff)}"

        # A dashboard errand, not a dead end and not a crash: the link is there
        # and nothing is reported as errored.
        assert has_element?(context.view, "[data-test='domain-dashboard-link']"),
               "expected a link to the dashboard where the domain can be registered"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected an unsupported TLD to hand off, not error"

        {:ok, context}
      end

      then_ "nothing is claimed or bought on Sam's behalf", context do
        # Adopting the domain once he has registered it in the dashboard is
        # criterion 8052's territory — here the only claim is that setup does
        # not pretend to own or buy a name it cannot sell.
        refute has_element?(context.view, "[data-test='domain-registered']"),
               "expected setup to claim nothing for an extension it cannot sell"

        refute has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected no in-app purchase for an extension the API cannot sell"

        {:ok, context}
      end
    end
  end
end
