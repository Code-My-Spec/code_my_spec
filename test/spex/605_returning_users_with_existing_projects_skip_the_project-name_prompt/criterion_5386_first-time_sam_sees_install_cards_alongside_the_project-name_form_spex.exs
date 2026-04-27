defmodule CodeMySpecSpex.Story605.Criterion5386Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects skip the project-name prompt
  Criterion 5386 — First-time Sam sees install cards alongside the project-name form.

  On initial empty-state visit, Sam should see BOTH the project-name form AND
  the two install-guidance cards in the same page render — not one or the other.
  The form being present must not suppress the install guidance.

  Observed through the initial LiveView render (no interaction needed).
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  spex "First-time Sam sees install cards alongside the project-name form" do
    scenario "First-time Sam sees install cards alongside the project-name form" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      then_ "the project-name form is rendered", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected the project-name input to be present on the initial render " <>
                 "for a first-time user"

        :ok
      end

      then_ "the Claude Code install card is also rendered on the same page", context do
        assert context.html =~ "plugin marketplace add",
               "expected the Claude Code install instructions to appear alongside " <>
                 "the project-name form on /app/onboarding for a first-time user"

        :ok
      end

      then_ "the Stories MCP card is also rendered on the same page", context do
        assert context.html =~ "/mcp/stories",
               "expected the Stories MCP card to appear alongside the project-name " <>
                 "form on /app/onboarding for a first-time user"

        :ok
      end
    end
  end
end
