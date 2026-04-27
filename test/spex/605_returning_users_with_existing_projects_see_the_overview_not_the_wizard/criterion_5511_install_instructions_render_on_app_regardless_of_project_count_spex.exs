defmodule CodeMySpecSpex.Story605.Criterion5511Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects see the Overview,
  not the wizard.
  Criterion 5511 — Rule: Install instructions (Claude Code extension,
  Stories MCP) render on /app regardless of project count.

  Two spex blocks (one ExUnit test each, fresh DB sandbox per spex):

  1. First-time user (zero projects) — install cards render alongside
     the project-name form.
  2. Returning user (with a project) — install cards render alongside
     the Overview view.
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

      then_ "the Claude Code install card is rendered on the same page", context do
        assert context.html =~ "plugin marketplace add",
               "expected the Claude Code install instructions alongside the " <>
                 "project-name form for a first-time user"

        {:ok, context}
      end

      then_ "the Stories MCP card is rendered on the same page", context do
        assert context.html =~ "/mcp/stories",
               "expected the Stories MCP card alongside the project-name form " <>
                 "for a first-time user"

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

        assert rendered =~ "Install the Claude Code extension",
               "expected the 'Install the Claude Code extension' card heading"

        {:ok, context}
      end

      then_ "the Stories MCP card is visible", context do
        rendered = render(context.view)

        assert rendered =~ "/mcp/stories",
               "expected the Stories MCP server URL on /app for a returning user"

        assert rendered =~ "Just want to draft stories?",
               "expected the 'Just want to draft stories?' card to be visible"

        {:ok, context}
      end
    end
  end
end
