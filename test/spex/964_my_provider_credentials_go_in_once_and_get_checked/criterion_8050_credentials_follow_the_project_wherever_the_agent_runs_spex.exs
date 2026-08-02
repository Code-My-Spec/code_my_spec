defmodule CodeMySpecSpex.Story964.Criterion8050Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 8050 — Credentials follow the project, wherever the agent runs.

  Credentials belong to the project, not to a machine or a shell. Setup
  reads them from the project's own store, so the same credentials serve
  a run started from Sam's laptop and a run started by a cloud agent.
  That is why they live in a scoped table rather than the process
  environment.

  Observably: entering credentials in one session and re-entering the
  project from a *fresh* connection still finds them recorded. A
  process-environment credential would not survive that.

  Surface: `CodeMySpecWeb.CredentialsLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Credentials follow the project, wherever the agent runs" do
    scenario "credentials entered once are found again from a fresh connection" do
      given_ "Sam entered his credentials for the project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='credentials-form']",
          credentials: %{hetzner_api_token: "project-scoped-token"}
        )
        |> render_submit()

        {:ok, context}
      end

      when_ "setup runs for that project from a fresh connection", context do
        # A new conn stands in for "a different runner" — nothing carried
        # over in process state, only what the project itself holds.
        fresh_conn = Phoenix.ConnTest.build_conn() |> log_in_user(context.user)

        {:ok, view, html} =
          live(fresh_conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "it reads them from the project's own store", context do
        assert has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential='hetzner_api_token'][data-stored='true']"
               ),
               "expected the project's stored credential to be visible from a fresh connection"

        {:ok, context}
      end

      then_ "the value itself is not handed back to the page", context do
        refute context.html =~ "project-scoped-token",
               "expected the stored value never to be rendered back into the page"

        {:ok, context}
      end
    end
  end
end
