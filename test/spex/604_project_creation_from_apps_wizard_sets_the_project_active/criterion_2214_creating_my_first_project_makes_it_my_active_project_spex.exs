defmodule CodeMySpecSpex.Story604.Criterion2214Spex do
  @moduledoc """
  Story 604 — Project creation from onboarding sets the project active
  and redirects to the app
  Criterion 2214 — Creating my first project makes it my active project.

  Title-only criterion; no scenario was recorded against it. Driven as a
  mechanical reading of the title: after onboarding creates the first
  project, /app has to show it as the active one — not merely present in
  a listing (criterion 283) and not merely free of a picker bounce
  (criterion 284), but recognized by name as *the* project. `AppLive.Overview`
  renders that recognition as the project rung's "done" state, whose value
  is the active project's name.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Creating my first project makes it my active project", criterion: 2214 do
    scenario "The newly-created project renders as the active project on /app" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "they submit the project-name form with a valid name", context do
        context.view
        |> form("#project_form", project: %{name: "My First Project"})
        |> render_submit()

        _target = assert_redirect(context.view)

        {:ok, Map.put(context, :conn, recycle(context.conn))}
      end

      then_ "the project rung on /app shows it as the done, active project", context do
        conn = get(context.conn, "/app")
        html = html_response(conn, 200)

        assert html =~ ~s|data-test="project-rung"|,
               "expected the project rung to render on /app"

        assert html =~ ~s|data-state="done"|,
               "expected the project rung to read as done, not still asking for a name"

        assert html =~ "My First Project",
               "expected the project rung's value to name the project just created, " <>
                 "not fall through to some other project or none at all"

        {:ok, context}
      end
    end
  end
end
