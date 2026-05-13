defmodule CodeMySpecSpex.Story605.Criterion5384Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects see the Overview,
  not the wizard.
  Criterion 5384 — A project added in another tab does NOT flip the
  project-name form mid-render in the original session.

  The "has projects" check is evaluated once at /app mount time, not as
  a live assign. So Tab A — already mounted on /app showing the
  project-name form — stays on the form even after Tab B creates a
  project for the same active account. Re-evaluation only happens on
  the next page load (refresh / re-mount).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "A project added in another tab does not flip the form mid-session" do
    scenario "Tab B creates a project; Tab A keeps the project-name form without a refresh" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      and_ "Tab A initially shows the project-name form", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "precondition: expected the project-name form on Tab A at mount"

        {:ok, context}
      end

      when_ "Tab B creates a project for the same user account", context do
        tab_b_conn =
          Phoenix.ConnTest.dispatch(
            Phoenix.ConnTest.recycle(context.conn),
            CodeMySpecWeb.Endpoint,
            :get,
            "/app"
          )

        {:ok, tab_b_view, _html} = Phoenix.LiveViewTest.live(tab_b_conn)

        tab_b_view
        |> form("#project_form", project: %{name: "Tab B Project"})
        |> render_submit()

        {:ok, Map.put(context, :tab_b_view, tab_b_view)}
      end

      then_ "Tab A still shows the project-name input without a refresh", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected Tab A to still show the project-name form after a project " <>
                 "was created in Tab B — the check must not flip mid-session"

        {:ok, context}
      end
    end
  end
end
