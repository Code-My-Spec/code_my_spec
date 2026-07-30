defmodule CodeMySpecSpex.Story963.Criterion7966Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7966 — The domain purchase round-trip resumes on return.

  Some work Sam has to do elsewhere. When the TLD sits outside what the
  Registrar API can sell, setup pauses and tells him exactly what to do
  in the Cloudflare dashboard — then, when he comes back, finds the
  registered domain and carries on to the next step. Pausing without
  telling him what to do, or losing the run while he is away, both fail
  this.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @unsupported_cassette "cloudflare_tld_not_available_via_api"
  @adopted_cassette "cloudflare_zone_found_after_manual_registration"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The domain purchase round-trip resumes on return" do
    scenario "an unsupported TLD pauses with instructions and resumes when the domain exists" do
      given_ "the domain Sam wants has a TLD the Registrar API cannot sell", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs", context do
        ReqCassette.with_cassette(@unsupported_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup pauses and tells him what to do in the Cloudflare dashboard", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected the domain step to pause rather than error or press on"

        instructions =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='paused-instructions'][data-step='domain']")
          |> Floki.text()

        assert instructions =~ ~r/dashboard|cloudflare/i,
               "expected the pause to say what to do in the dashboard, got: #{inspect(instructions)}"

        {:ok, context}
      end

      then_ "when Sam returns, setup finds the domain and continues", context do
        ReqCassette.with_cassette(@adopted_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='resume-setup']") |> render_click()
        end)

        html = render(context.view)

        assert html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected setup to adopt the manually registered domain on return"

        refute html =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected the pause to clear once the domain existed"

        {:ok, context}
      end
    end
  end
end
