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

  @paused_cassette "cloudflare_tld_not_available_via_api"
  @still_missing_cassette "cloudflare_zone_still_absent"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coming back without doing the thing keeps setup paused" do
    scenario "resuming with the domain still unregistered stays paused on the same step" do
      given_ "setup is paused waiting for Sam to register the domain", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@paused_cassette, [mode: :replay], fn ->
          view |> element("[data-test='start-setup']") |> render_click()
        end)

        assert render(view) =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected setup to be paused on the domain step before resuming"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam returns without having registered it", context do
        ReqCassette.with_cassette(@still_missing_cassette, [mode: :replay], fn ->
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
