defmodule CodeMySpecSpex.Story605.Criterion5509Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects skip the project-name prompt
  Criterion 5509 — Returning Sam with one project sees install instructions,
  no project-name input.

  A user who has already created a project visits /app again.
  The project-name form must NOT be rendered. The install instructions must
  still be visible. Observed entirely through the LiveView surface.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Returning user with one project sees install instructions, no project-name input" do
    scenario "Returning Sam with one project sees install instructions, no project-name input" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      when_ "Sam creates their first project via the onboarding form", context do
        context.view
        |> form("#project_form", project: %{name: "My First Project"})
        |> render_submit()

        {:ok, Map.put(context, :project_created, true)}
      end

      when_ "Sam navigates back to /app", context do
        onboarding_conn =
          Phoenix.ConnTest.dispatch(
            Phoenix.ConnTest.recycle(context.conn),
            CodeMySpecWeb.Endpoint,
            :get,
            "/app"
          )

        {:ok, view, html} = Phoenix.LiveViewTest.live(onboarding_conn)
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the project-name input is not rendered", context do
        refute has_element?(context.view, "input[name='project[name]']"),
               "expected the project-name input to be absent for a returning user " <>
                 "who already has a project in their active account"

        {:ok, context}
      end

      then_ "the install instructions are still visible", context do
        assert render(context.view) =~ "plugin marketplace add",
               "expected the Claude Code install instructions to remain on " <>
                 "/app regardless of project count"

        {:ok, context}
      end
    end
  end
end
