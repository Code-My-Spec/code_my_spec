defmodule CodeMySpecSpex.Story603.Criterion5370Spex do
  @moduledoc """
  Story 603 — Onboarding detects empty state and asks for a project name
  Criterion 5370 — Rule: When a logged-in user with an active account has
  zero projects, /app/onboarding renders a project-name text input.

  Setup uses the public registration + magic-link flow to put the user in
  the empty-state precondition (zero projects, active account selected).
  The assertion observes the LiveView's initial render.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "Onboarding renders a project-name input on empty state" do
    scenario "Empty-state user lands on onboarding and sees the project-name input" do
      given_ :registered_user_with_magic_link
      given_ :empty_state_user_on_onboarding

      then_ "the page renders a project-name text input", context do
        assert has_element?(context.view, "input[name='project[name]']"),
               "expected a project-name text input on /app/onboarding when the " <>
                 "user has zero projects in their active account"

        :ok
      end

      then_ "the input is labeled with a project-naming prompt", context do
        # Accept any prompt that mentions "project" and "name"/"call" — the
        # exact copy is left to design (see open question on label copy).
        assert context.html =~ ~r/(name|call).*?project/i or
                 context.html =~ ~r/project.*?(name|call)/i,
               "expected a project-naming prompt label on the onboarding page"

        :ok
      end
    end
  end
end
