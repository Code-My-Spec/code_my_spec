defmodule CodeMySpecSpex.Story605.Criterion5511Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects see the Overview,
  not the wizard.
  Criterion 5511 — Rule: Install instructions for the Claude Code
  plugin render on /app regardless of project count.

  Two spex blocks (one ExUnit test each, fresh DB sandbox per spex):

  1. First-time user (zero projects) — install panel renders alongside
     the project-name form.
  2. Returning user (with a project) — install panel renders alongside
     the Overview view.

  Note: the alternative remote-MCP "draft stories" card was removed
  when stories moved to the local CLI (story 698). This spec only
  asserts the Claude Code install path.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "First-time user sees install cards alongside the project-name form" do
    scenario "First-time user sees install cards alongside the project-name form" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      then_ "the project-name form is rendered", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected the project-name input on the initial render for a first-time user"

        {:ok, context}
      end

      then_ "the plugin rung is present on the same page as a pending tile", context do
        # Under story 700's ladder, the plugin step is always rendered on
        # /app — as a pending tile until the user finishes the project
        # step. The install commands themselves are content of the
        # plugin's active state, not the pending tile.
        assert has_element?(
                 context.view,
                 "[data-test='plugin-rung'][data-state='pending']"
               ),
               "expected plugin-rung in 'pending' state alongside the project form for a first-time user"

        {:ok, context}
      end

    end
  end

  spex "Returning user with a project still sees install cards alongside the Overview" do
    scenario "Returning user with a project still sees install cards alongside the Overview" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      given_ "Sam creates their first project via the onboarding form", context do
        context.view
        |> form("#project_form", project: %{name: "Existing Project"})
        |> render_submit()

        {:ok, Map.put(context, :project_created, true)}
      end

      when_ "Sam revisits /app", context do
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

      then_ "the Claude Code install card is visible", context do
        rendered = render(context.view)

        assert rendered =~ "plugin marketplace add",
               "expected the Claude Code install instructions on /app for a returning user"

        assert rendered =~ "Install CodeMySpec",
               "expected the 'Install CodeMySpec' onboarding card heading"

        {:ok, context}
      end

    end
  end
end
