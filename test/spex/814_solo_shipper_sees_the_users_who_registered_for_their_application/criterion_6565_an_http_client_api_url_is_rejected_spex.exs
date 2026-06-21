defmodule CodeMySpecSpex.Story814.Criterion6565Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6565 — An HTTP client API URL is rejected.

  Surface: the project edit form (`/projects/:id/edit`, `CodeMySpecWeb.ProjectLive.Form`).
  Saving a plain http client API URL is rejected with a validation error — the
  deploy key (and the users it guards) must never travel over plaintext http.

  Red until the project changeset rejects non-https client API URLs (today the
  format check accepts http). No outbound HTTP: form-validation scenario.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An http client API URL is rejected" do
    scenario "An HTTP client API URL is rejected" do
      given_ "Sam is on the project edit form", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")
        {:ok, Map.put(context, :form_live, form_live)}
      end

      when_ "Sam sets the client API URL to an http address and saves", context do
        html =
          context.form_live
          |> form("#project-form", project: %{client_api_url: "http://app.example.com"})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees a validation error and the URL is not accepted", context do
        assert context.html =~ "must use https",
               "expected a plaintext http client API URL to be rejected, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
