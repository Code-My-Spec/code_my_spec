defmodule CodeMySpecSpex.Story604.Criterion2214Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 2214 — Creating my first project makes it my active project.

  Observed through the public surface: after the project-name form is
  submitted, the app entry the user lands on works on that project, with no
  picker to choose it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Creating my first project makes it my active project", criterion: 2214 do
    scenario "the app entry I land on works on the project I just created" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "I create my first project", context do
        context.view
        |> form("#project_form", project: %{name: "My First Project"})
        |> render_submit()

        {path, _flash} = assert_redirect(context.view)
        {:ok, Map.merge(context, %{conn: recycle(context.conn), landed_on: path})}
      end

      then_ "the app I land on is working on that project", context do
        html = context.conn |> get(context.landed_on) |> html_response(200)

        assert html =~ "My First Project",
               "expected #{context.landed_on} to work on the project just created"

        {:ok, context}
      end
    end
  end
end
