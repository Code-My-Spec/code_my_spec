defmodule CodeMySpecSpex.Story964.Criterion7985Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7985 — A missing credential stops the run before it starts.

  With the email option on and no Resend key supplied, setup refuses to
  start and says which credential is missing. Refusing up front is the
  whole point: a run that starts and dies at the email step has already
  provisioned a server and a domain on the way there.

  Surface: `CodeMySpecWeb.ProvisioningLive` / `CredentialsLive` on the
  cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A missing credential stops the run before it starts" do
    scenario "setup refuses to start and names the credential it lacks" do
      given_ "the email option is on and no Resend key has been entered", context do
        # Email is on by default and intake has not been completed, so the
        # Resend credential is genuinely absent — not cleared afterwards.
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he tries to start setup", context do
        html =
          context.view
            |> element("[data-test='start-setup']")
            |> render_click()

            # Started, not finished: the click returns as soon as the run
            # begins, so the page is read once the run settles.
            await_provisioning(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup refuses to start and says which credential is missing", context do
        assert context.html =~ "Resend",
               "expected the refusal to name the missing Resend credential"

        refute has_element?(context.view, "[data-test='setup-step'][data-state='running']"),
               "expected no step to be running after setup refused to start"

        {:ok, context}
      end

      then_ "nothing has been provisioned", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        refute has_element?(view, "[data-test='setup-step'][data-state='done']"),
               "expected no step to have completed when setup refused to start"

        {:ok, context}
      end
    end
  end
end
