defmodule CodeMySpecSpex.Story814.Criterion6564Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6564 — An HTTPS client API URL is accepted.

  Surface: the project edit form (`/projects/:id/edit`, `CodeMySpecWeb.ProjectLive.Form`).
  Saving an https client API URL succeeds — the deploy key is only ever sent
  over https, so https URLs are the accepted form.

  No outbound HTTP: this is a form-validation scenario.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An https client API URL is accepted" do
    scenario "An HTTPS client API URL is accepted" do
      given_ "Sam is on the project edit form", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")
        {:ok, Map.put(context, :form_live, form_live)}
      end

      when_ "Sam sets the client API URL to an https address and saves", context do
        {:ok, _view, html} =
          context.form_live
          |> form("#project-form", project: %{client_api_url: "https://app.example.com"})
          |> render_submit()
          |> follow_redirect(context.conn)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the URL is accepted", context do
        assert context.html =~ "updated successfully",
               "expected the https client API URL to save, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
