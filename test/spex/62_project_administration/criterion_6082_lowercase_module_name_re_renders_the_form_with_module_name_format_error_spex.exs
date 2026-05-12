defmodule CodeMySpecSpex.Story62.Criterion6082Spex do
  @moduledoc """
  Story 62 — Project Administration
  Criterion 6082 — Submitting the new-project form with a module_name
  that does not match the Elixir module format (`^[A-Z][a-zA-Z0-9]*$`)
  re-renders the form with a "must be a valid Elixir module name"
  error. No project is created.

  Surface: Project changeset's validate_format(:module_name, ...).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Project form rejects a malformed module_name" do
    scenario "Lowercase module_name re-renders the form with the format error" do
      given_ "the user is on /app/projects/new", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/new")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the user submits a name plus a lowercase module_name", context do
        rendered =
          context.view
          |> form("#project-form", project: %{name: "ok", module_name: "lowercase_mod"})
          |> render_submit()

        {:ok, Map.put(context, :rendered, rendered)}
      end

      then_ "the form re-renders with the module-name format error", context do
        assert context.rendered =~ "New Project",
               "anchor: expected the form to re-render (page header still present)"

        assert context.rendered =~ "must be a valid Elixir module name",
               "expected the Elixir module-name format error on the form"

        {:ok, context}
      end

      and_ "the index does not contain the rejected project", context do
        {:ok, _index_live, index_html} = live(context.conn, "/app/projects")

        assert index_html =~ "Projects",
               "anchor: expected the projects index header to render"

        refute index_html =~ "lowercase_mod",
               "expected no project bearing the rejected module_name"

        {:ok, context}
      end
    end
  end
end
