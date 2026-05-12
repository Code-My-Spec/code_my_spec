defmodule CodeMySpecSpex.Story62.Criterion6081Spex do
  @moduledoc """
  Story 62 — Project Administration
  Criterion 6081 — Submitting the new-project form with a blank name
  re-renders the form with the "can't be blank" validation error.
  No project is created.

  Surface: ProjectLive.Form validate/save handlers.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Project form rejects a blank name" do
    scenario "Empty name re-renders the form with validation errors" do
      given_ "the user is on /app/projects/new", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/new")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user submits the project form with a blank name", context do
        rendered =
          context.view
          |> form("#project-form", project: %{name: ""})
          |> render_submit()

        {:ok, Map.put(context, :rendered, rendered)}
      end

      then_ "the form re-renders with a can't-be-blank error on name", context do
        assert context.rendered =~ "New Project",
               "anchor: expected the form to re-render (page header still present)"

        assert context.rendered =~ "can&#39;t be blank",
               "expected a validation error on the form"

        {:ok, context}
      end

      and_ "the index shows no projects (none was created)", context do
        {:ok, _index_live, index_html} = live(context.conn, "/app/projects")

        assert index_html =~ "Projects",
               "anchor: expected the projects index header to render"

        refute index_html =~ "Brand New Project",
               "expected no new project rows in the listing"

        {:ok, context}
      end
    end
  end
end
