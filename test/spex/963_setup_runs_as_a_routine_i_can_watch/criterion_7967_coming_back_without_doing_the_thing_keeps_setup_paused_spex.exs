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

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Coming back without doing the thing keeps setup paused" do
    scenario "resuming with the domain still unregistered stays paused on the same step" do
      given_ "setup is paused waiting for Sam to register the domain", context do
        # Pauses every time, because the errand was never done. That is the
        # criterion: coming back changes nothing on its own, and setup must not
        # decide it is satisfied just because it was asked twice.
        context =
          scripted_run(context, %{
            domain:
              {:paused,
               "Register this domain in the Cloudflare dashboard, then run this step again."}
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        await_provisioning(view)

        assert render(view) =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected setup to be paused on the domain step before resuming"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam returns without having registered it", context do
        context.view |> element("[data-test='resume-setup']") |> render_click()
        html = await_provisioning(context.view)

        {:ok, Map.put(context, :html, html)}
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
