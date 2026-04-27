defmodule CodeMySpecSpex.Story604.Criterion5374Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 5374 — Rule: New project belongs to the user's active account.

  Observed via the public surface — after onboarding submit, the user
  reaches /app/projects (account-scoped listing) and sees the new
  project in the list.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Created project belongs to the user's active account" do
    scenario "Created project is scoped to the user's active account" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit the project-name form with a valid name", context do
        context.view
        |> form("#project_form", project: %{name: "My First Project"})
        |> render_submit()

        _target = assert_redirect(context.view)

        {:ok, Map.put(context, :conn, recycle(context.conn))}
      end

      then_ "the new project appears in the active account's project listing", context do
        conn = get(context.conn, "/app/projects")
        html = html_response(conn, 200)

        assert html =~ "My First Project",
               "expected the new project to appear in /app/projects (account-scoped listing)"

        {:ok, context}
      end
    end
  end
end
