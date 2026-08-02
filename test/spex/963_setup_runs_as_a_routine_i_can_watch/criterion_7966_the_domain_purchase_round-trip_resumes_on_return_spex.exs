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

  @unsupported_cassette "963_7966_cloudflare_tld_not_available_via_api"
  @adopted_cassette "cloudflare_zone_found_after_manual_registration"
  @given_cassette "963_7966_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The domain purchase round-trip resumes on return" do
    scenario "an unsupported TLD pauses with instructions and resumes when the domain exists" do
      given_ "the domain Sam wants has a TLD the Registrar API cannot sell", context do
        # Before the page mounts. The LiveView reads the project once, at mount;
        # claiming the repository afterwards updates the row but not the socket,
        # so the step still saw a repository belonging to nobody and paused.
        own_repository(context.project)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Hetzner has no OAuth, so its token is pasted per project — without it
        # the server step stops at `hetzner_not_configured` and every claim
        # downstream fails for a reason that is not the one under test. Saving a
        # credential proves it with a real provider call, so it belongs inside a
        # cassette.
        tear_down_after(context.scope, [:server])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)


        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs", context do
        with_provider_cassette(@unsupported_cassette, fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()

          # The repository an earlier recording made cannot be deleted (the grant
          # has no `delete_repo` scope), so the run pauses on the name and every
          # step under test stays not_started. Adopting is the honest answer.
          adopt_repository_if_paused(context.view)
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
        with_provider_cassette(@adopted_cassette, fn ->
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
