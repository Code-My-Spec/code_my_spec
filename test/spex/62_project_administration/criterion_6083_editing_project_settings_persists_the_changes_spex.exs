defmodule CodeMySpecSpex.Story62.Criterion6083Spex do
  @moduledoc """
  Story 62 — Project Administration
  Criterion 6083 — Submitting the edit form at /app/projects/:id/edit
  with a new name persists the change. The user is redirected back to
  the index and the new name appears there and on the project show
  page.

  Surface: ProjectLive.Form (live_action :edit) at /app/projects/:id/edit.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "Editing an existing project persists the new settings" do
    scenario "Edit form updates the project and the new name surfaces in the index and show page" do
      given_ "an existing project in the active account", context do
        project =
          Fixtures.project_fixture(context.scope,
            name: "Old Name"
          )

        {:ok, Map.put(context, :project, project)}
      end

      when_ "the user submits the edit form with a new name", context do
        {:ok, form_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/edit")

        {:ok, index_live, _html} =
          form_live
          |> form("#project-form", project: %{name: "Renamed Project"})
          |> render_submit()
          |> follow_redirect(context.conn, "/app/projects")

        {:ok, Map.put(context, :index_view, index_live)}
      end

      then_ "the index shows the new name and an update success flash", context do
        rendered = render(context.index_view)

        assert rendered =~ "Project updated successfully",
               "expected the update success flash"

        assert rendered =~ "Renamed Project",
               "expected the renamed project in the listing"

        refute rendered =~ "Old Name",
               "expected the old project name to be gone from the listing"

        {:ok, context}
      end

      and_ "the project show page reflects the new name", context do
        {:ok, _show_live, show_html} =
          live(context.conn, "/app/projects/#{context.project.id}")

        assert show_html =~ "Renamed Project",
               "expected the show page to render the new name"

        {:ok, context}
      end
    end
  end
end
