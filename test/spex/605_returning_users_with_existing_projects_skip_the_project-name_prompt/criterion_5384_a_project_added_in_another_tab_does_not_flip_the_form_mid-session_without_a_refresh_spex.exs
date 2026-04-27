defmodule CodeMySpecSpex.Story605.Criterion5384Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects skip the project-name prompt
  Criterion 5384 — A project added in another tab does not flip the form mid-session
  without a refresh.

  `empty_state?` is computed once at mount and is NOT a live-updated assign. So
  if Tab A has onboarding open (form visible, empty state), and Tab B creates a
  project, Tab A must NOT reactively hide the form — the user must refresh to see
  the updated state.

  We simulate "another tab" by mounting a second LiveView connection for the same
  user and submitting the project form there, then asserting the first view is
  unchanged. This is the highest-fidelity test available without a full browser
  (Wallaby) harness.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "A project added in another tab does not flip the form mid-session" do
    scenario "A project added in another tab does not flip the form mid-session without a refresh" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "Tab B creates a project for the same user account", context do
        # Precondition: the form is visible in Tab A (the original session).
        assert has_element?(context.view, "input[name='project[name]']"),
               "precondition failed: expected form to be visible in Tab A at mount"

        # Open a second LiveView connection for the same user (same session cookie).
        tab_b_conn =
          Phoenix.ConnTest.dispatch(
            Phoenix.ConnTest.recycle(context.conn),
            CodeMySpecWeb.Endpoint,
            :get,
            "/app/onboarding"
          )

        {:ok, tab_b_view, _html} = Phoenix.LiveViewTest.live(tab_b_conn)

        tab_b_view
        |> form("#project_form", project: %{name: "Tab B Project"})
        |> render_submit()

        {:ok, Map.put(context, :tab_b_view, tab_b_view)}
      end

      then_ "Tab A still shows the project-name input without a refresh", context do
        # The project now exists in the DB, but Tab A's `empty_state?` was computed
        # at mount and is not a reactive assign. The form should still be present.
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected Tab A to still show the project-name form after a project " <>
                 "was created in Tab B — `empty_state?` must not flip mid-session " <>
                 "without a page refresh"

        :ok
      end
    end
  end
end
