defmodule CodeMySpecSpex.Story963.Criterion7967Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7967 — Coming back without doing the thing keeps setup paused.

  Returning is not the same as having done the errand. If Sam comes back
  without registering the domain, setup stays paused on the same step and
  repeats what still needs doing — it does not take his return as proof
  and march on into a deploy with no domain.

  Retargeted onto the console (provisioning-console-step6, unmerged): there
  is no `resume-setup`/whole-run to come back to, but the claim under test —
  that re-running a paused step does not treat the return as proof the
  errand was done — is a per-step property regardless of how the re-run is
  reached. Running `:domain` a second time directly via `run_console_step/2`
  tests it the same way `resume-setup` did.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Coming back without doing the thing keeps setup paused", criterion: 572 do
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
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/dns_domain")

        run_console_step(view, :domain)

        assert render(view) =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected setup to be paused on the domain step before resuming"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam returns without having registered it", context do
        run_console_step(context.view, :domain)

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
