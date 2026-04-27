defmodule CodeMySpecSpex.Story605.Criterion5385Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects skip the project-name prompt
  Criterion 5385 — Returning Sam still sees Claude Code install card and stories
  MCP card.

  Even though the project-name form is suppressed for returning users, the two
  install-guidance cards (Claude Code extension and Stories MCP) must remain
  visible — they are not conditional on `empty_state?`.

  Observed through the LiveView render after Sam has created a project and
  revisited /app/onboarding.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Returning Sam still sees Claude Code install card and Stories MCP card" do
    scenario "Returning Sam still sees Claude Code install card and stories MCP card" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      given_ "Sam creates their first project via the onboarding form", context do
        context.view
        |> form("#project_form", project: %{name: "Existing Project"})
        |> render_submit()

        {:ok, Map.put(context, :project_created, true)}
      end

      when_ "Sam revisits /app/onboarding", context do
        onboarding_conn =
          Phoenix.ConnTest.dispatch(
            Phoenix.ConnTest.recycle(context.conn),
            CodeMySpecWeb.Endpoint,
            :get,
            "/app/onboarding"
          )

        {:ok, view, html} = Phoenix.LiveViewTest.live(onboarding_conn)
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the Claude Code install card is visible", context do
        rendered = render(context.view)

        assert rendered =~ "plugin marketplace add",
               "expected the Claude Code install instructions to be visible on " <>
                 "/app/onboarding for a returning user (non-conditional content)"

        assert rendered =~ "Install the Claude Code extension",
               "expected the 'Install the Claude Code extension' card heading to " <>
                 "be visible for a returning user"

        {:ok, context}
      end

      then_ "the Stories MCP card is visible", context do
        rendered = render(context.view)

        assert rendered =~ "/mcp/stories",
               "expected the Stories MCP server URL to appear on /app/onboarding " <>
                 "for a returning user (non-conditional content)"

        assert rendered =~ "Just want to draft stories?",
               "expected the 'Just want to draft stories?' card to be visible " <>
                 "for a returning user"

        {:ok, context}
      end
    end
  end
end
