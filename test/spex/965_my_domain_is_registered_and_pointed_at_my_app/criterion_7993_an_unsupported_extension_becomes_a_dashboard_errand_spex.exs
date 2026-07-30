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

  @unsupported_cassette "cloudflare_tld_not_available_via_api"
  @adopted_cassette "cloudflare_zone_found_after_manual_registration"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unsupported extension becomes a dashboard errand" do
    scenario "an out-of-beta TLD is handed off and then adopted on return" do
      given_ "Sam wants a domain whose extension the API cannot sell", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs", context do
        html =
          ReqCassette.with_cassette(@unsupported_cassette, [mode: :replay], fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.io"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup tells him to register it in the Cloudflare dashboard", context do
        instructions =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='paused-instructions'][data-step='domain']")
          |> Floki.text()

        assert instructions =~ ~r/dashboard/i,
               "expected a dashboard errand rather than a failure, got: #{inspect(instructions)}"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected an unsupported TLD to pause, not error"

        {:ok, context}
      end

      then_ "when he returns, setup finds the domain and carries on from there", context do
        ReqCassette.with_cassette(@adopted_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='resume-setup']") |> render_click()
        end)

        html = render(context.view)

        assert html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected setup to adopt the manually registered domain and continue"

        {:ok, context}
      end
    end
  end
end
