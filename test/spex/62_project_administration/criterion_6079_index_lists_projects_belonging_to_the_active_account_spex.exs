defmodule CodeMySpecSpex.Story62.Criterion6079Spex do
  @moduledoc """
  Story 62 — Project Administration
  Criterion 6079 — The /app/projects index lists projects that belong
  to the user's active account.

  Surface: ProjectLive.Index LiveView at /app/projects. The list is
  streamed from Projects.list_projects(scope), which scopes through
  current_scope.active_account_id.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "Projects index is scoped to the active account" do
    scenario "Index lists projects belonging to the active account" do
      given_ "a project exists in the user's active account", context do
        project =
          Fixtures.project_fixture(context.scope,
            name: "Active Account Project"
          )

        {:ok, Map.put(context, :project, project)}
      end

      when_ "the user visits /app/projects", context do
        {:ok, view, html} = live(context.conn, "/app/projects")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the projects index renders the active-account project", context do
        assert context.html =~ "Projects",
               "anchor: expected the projects index header to render"

        assert render(context.view) =~ context.project.name,
               "expected the active-account project to appear in the listing"

        {:ok, context}
      end
    end
  end
end
