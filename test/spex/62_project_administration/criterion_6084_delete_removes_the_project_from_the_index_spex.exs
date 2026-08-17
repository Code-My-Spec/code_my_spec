defmodule CodeMySpecSpex.Story62.Criterion6084Spex do
  @moduledoc """
  Story 62 — Project Administration
  Criterion 6084 — Clicking the Delete link on a project row removes
  the project. The row disappears from the streaming list and a
  subsequent fresh mount of /app/projects no longer shows the project.

  Surface: ProjectLive.Index handle_event("delete", ...) +
  Projects.delete_project + the streaming list.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "Delete removes a project from the index" do
    scenario "Clicking Delete removes the row and a fresh mount no longer shows it" do
      given_ "an existing project in the active account, visible on /app/projects", context do
        project =
          Fixtures.project_fixture(context.scope,
            name: "Doomed Project"
          )

        {:ok, view, html} = live(context.conn, "/app/projects")

        assert html =~ project.name,
               "precondition: expected the project to appear in the initial listing"

        {:ok, Map.merge(context, %{project: project, view: view})}
      end

      when_ "the user triggers the Delete event for the project", context do
        _rendered_after_delete =
          context.view
          |> render_click("delete", %{id: context.project.id})

        {:ok, context}
      end

      then_ "the project row is no longer present after a fresh mount", context do
        {:ok, _fresh_view, fresh_html} = live(context.conn, "/app/projects")

        assert fresh_html =~ "Projects",
               "anchor: expected the projects index header to render"

        refute fresh_html =~ context.project.name,
               "expected the deleted project to be gone from a fresh mount of /app/projects"

        {:ok, context}
      end
    end
  end
end
