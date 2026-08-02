defmodule CodeMySpecSpex.Story963.Criterion7967Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7967 — Coming back without doing the thing keeps setup paused.

  Returning is not the same as having done the errand. If Sam comes back
  without registering the domain, setup stays paused on the same step and
  repeats what still needs doing — it does not take his return as proof
  and march on into a deploy with no domain.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @paused_cassette "963_7967_cloudflare_tld_not_available_via_api"
  @still_missing_cassette "cloudflare_zone_still_absent"
  @given_cassette "963_7967_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Coming back without doing the thing keeps setup paused" do
    scenario "resuming with the domain still unregistered stays paused on the same step" do
      given_ "setup is paused waiting for Sam to register the domain", context do
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

        with_provider_cassette(@paused_cassette, fn ->
          view |> element("[data-test='start-setup']") |> render_click()

          # The repository an earlier recording made cannot be deleted (the grant
          # has no `delete_repo` scope), so the run pauses on the name and every
          # step under test stays not_started. Adopting is the honest answer.
          adopt_repository_if_paused(view)
        end)

        assert render(view) =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected setup to be paused on the domain step before resuming"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam returns without having registered it", context do
        with_provider_cassette(@still_missing_cassette, fn ->
          context.view |> element("[data-test='resume-setup']") |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup stays paused on the same step", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected the domain step to remain paused when the domain still does not exist"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected setup not to treat Sam's return as proof the errand was done"

        {:ok, context}
      end

      then_ "it repeats what still needs doing", context do
        instructions =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='paused-instructions'][data-step='domain']")
          |> Floki.text()

        assert instructions =~ ~r/dashboard|cloudflare|register/i,
               "expected the outstanding instructions to be restated, got: #{inspect(instructions)}"

        {:ok, context}
      end
    end
  end
end
