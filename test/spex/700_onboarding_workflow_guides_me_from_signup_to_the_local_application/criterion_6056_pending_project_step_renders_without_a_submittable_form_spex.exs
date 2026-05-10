defmodule CodeMySpecSpex.Story700.Criterion6056Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6056 — Rule: A pending (not-yet-reached) step is
  non-actionable — its form is not submittable, its link is not
  clickable, and it does not respond to user input.

  A user with no account sees the project rung as a pending tile.
  The active project form (with name input + submit button) must
  not be present in the DOM yet — the user can't skip ahead by
  forging a submit.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Pending project step renders as a tile, not an active form" do
    scenario "Pending project step renders without a submittable form" do
      given_ "the user is on /app with no account", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the project rung is in the pending state", context do
        assert has_element?(context.view, "[data-test='project-rung'][data-state='pending']"),
               "expected project-rung in 'pending' state until account is done"

        {:ok, context}
      end

      then_ "the project name input field is not present in the DOM", context do
        # Anchor: the project rung itself IS rendered (as a tile).
        assert has_element?(context.view, "[data-test='project-rung']")

        refute has_element?(context.view, "form#project_form"),
               "did not expect form#project_form to render while project step is pending"

        refute has_element?(context.view, "input[name='project[name]']"),
               "did not expect a project name input while project step is pending"

        {:ok, context}
      end
    end
  end
end
