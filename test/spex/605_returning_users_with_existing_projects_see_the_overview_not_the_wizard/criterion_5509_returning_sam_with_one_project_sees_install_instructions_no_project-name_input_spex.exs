defmodule CodeMySpecSpex.Story605.Criterion5509Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects skip the project-name prompt
  Criterion 5509 — Returning Sam with one project is not asked to name a
  project again.

  A user who has already created a project visits /app again. The
  project-name form must NOT be rendered. Observed entirely through the
  LiveView surface.

  The criterion also required the Claude Code install instructions to stay
  visible. `f84dffb9` took that card off /app — the dashboard cannot observe
  whether a plugin was installed, so the instructions moved to the pages that
  own installation. What made this criterion part of story 605 — a returning
  user is not re-asked the wizard question — is unchanged, and is what it now
  asserts. The rung's absence is covered by story 700.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Returning user with one project is not shown the project-name input" do
    scenario "Returning Sam with one project sees no project-name input" do
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

      then_ "the overview itself is what rendered", context do
        # Anchor: the refute above would also pass on an error page, so name
        # something the returning-user overview actually shows.
        assert has_element?(context.view, "[data-test='project-rung'][data-state='done']"),
               "expected the returning user's project rung to read done"

        {:ok, context}
      end
    end
  end
end
