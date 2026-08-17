defmodule CodeMySpecSpex.Story605.Criterion5512Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects skip the project-name prompt
  Criterion 5512 — First-time Sam with zero projects still sees the project-name input.

  The guard must not over-suppress: a brand-new user who has no projects at all
  must still see the project-name input when they land on /app.
  Observed through the initial LiveView render.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  spex "First-time Sam with zero projects still sees the project-name input" do
    scenario "First-time Sam with zero projects still sees the project-name input" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      then_ "the project-name input is present on the initial render", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected a project-name input to be rendered for a first-time user " <>
                 "who has no projects in their active account"

        {:ok, context}
      end

      then_ "the page prompts Sam to name their first project", context do
        assert context.html =~
                 ~r/name.*?first.*?project|first.*?project.*?name|call.*?first.*?project/i,
               "expected a prompt asking the user to name their first project " <>
                 "on /app when in empty state"

        {:ok, context}
      end
    end
  end
end
