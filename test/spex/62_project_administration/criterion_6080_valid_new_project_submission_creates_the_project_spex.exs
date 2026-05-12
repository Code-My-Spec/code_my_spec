defmodule CodeMySpecSpex.Story62.Criterion6080Spex do
  @moduledoc """
  Story 62 — Project Administration
  Criterion 6080 — Submitting the new-project form at /app/projects/new
  with a valid name creates the project, redirects back to /app/projects,
  and the new project appears in the index.

  Surface: ProjectLive.Form (live_action :new) at /app/projects/new.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "New-project form creates a project under the active account" do
    scenario "Valid submission creates the project and shows it in the index" do
      when_ "the user submits the project form with a valid name", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/new")

        {:ok, index_live, html} =
          form_live
          |> form("#project-form", project: %{name: "Brand New Project"})
          |> render_submit()
          |> follow_redirect(context.conn, "/app/projects")

        {:ok, Map.merge(context, %{view: index_live, html: html})}
      end

      then_ "the index shows the new project and a success flash", context do
        rendered = render(context.view)

        assert rendered =~ "Project created successfully",
               "expected the success flash to appear after creation"

        assert rendered =~ "Brand New Project",
               "expected the new project to appear in the index listing"

        {:ok, context}
      end
    end
  end
end
