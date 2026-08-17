defmodule CodeMySpecSpex.Story605.Criterion5510Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects see the Overview,
  not the wizard.
  Criterion 5510 — Rule: "Has projects" is scoped to the active account
  and evaluated at page-load time.

  Switching from a populated account to an empty one re-shows the
  project-name form on the next /app mount — proving the check is
  scoped to the *active* account, not the user's total projects.

  The "evaluated at page-load time (not mid-session reactive)" half of
  the rule is covered by 5384.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Switching to an empty account re-shows the project-name form on refresh" do
    scenario "Switching from a populated account to an empty one re-shows the form on refresh" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      given_ "Sam creates a project in their personal account", context do
        context.view
        |> form("#project_form", project: %{name: "Personal Project"})
        |> render_submit()

        {:ok, Map.put(context, :personal_project_created, true)}
      end

      when_ "Sam creates a new team account via /app/accounts", context do
        accounts_conn =
          Phoenix.ConnTest.dispatch(
            Phoenix.ConnTest.recycle(context.conn),
            CodeMySpecWeb.Endpoint,
            :get,
            "/app/accounts"
          )

        {:ok, accounts_view, _html} = Phoenix.LiveViewTest.live(accounts_conn)

        unique = System.unique_integer([:positive])
        team_name = "Team #{unique}"

        accounts_view
        |> element("button[phx-click='show-create-form']")
        |> render_click()

        accounts_view
        |> form("#create-account-form", account: %{name: team_name})
        |> render_submit()

        {:ok, Map.merge(context, %{accounts_view: accounts_view, team_name: team_name})}
      end

      when_ "Sam switches to the empty team account via the picker", context do
        picker_conn =
          Phoenix.ConnTest.dispatch(
            Phoenix.ConnTest.recycle(context.conn),
            CodeMySpecWeb.Endpoint,
            :get,
            "/app/accounts/picker"
          )

        {:ok, picker_view, _html} = Phoenix.LiveViewTest.live(picker_conn)

        picker_view
        |> element("a", context.team_name)
        |> render_click()

        {:ok, Map.put(context, :picker_view, picker_view)}
      end

      when_ "Sam navigates to /app after switching accounts", context do
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

      then_ "the project-name input is visible again for the empty team account", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected the project-name input to reappear on /app after switching " <>
                 "to a team account that has no projects"

        {:ok, context}
      end
    end
  end
end
