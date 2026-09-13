defmodule CodeMySpecSpex.Story1033.Criterion3418Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3418 — The panel swaps content without ever showing two things at
  once.

  Rule: the panel replaces its content as the conversation moves on; it never
  layers a later stage's content over an earlier one still showing.

  ## What this scenario can drive today, and what it cannot yet

  The full transition this criterion names — plan card to draft stories — has
  no draft-story generation to trigger yet (that mechanism belongs to this
  story's sibling work, not yet built). What is drivable today is the
  invariant itself, in the one state currently reachable: with the
  plan-confirmation card showing, nothing belonging to a later stage (draft
  stories, the sign-up card) is showing alongside it. A panel that violates
  the invariant here would violate it at the plan→stories boundary too — the
  bug this criterion is about is "the panel accumulates content" in general,
  not something that only appears at one specific transition.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "The panel shows one thing at a time, never a stack of them" do
    scenario "The panel swaps content without ever showing two things at once" do
      given_ "a visitor who has described and answered", context do
        conn = get(build_conn(), "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "the plan's guesses are ready and the panel shows the confirmation card", context do
        html = answer_shaping_questions(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the panel shows the plan card", context do
        assert has_element?(context.view, "[data-test='intake-plan']"),
               "expected the plan-confirmation card to be showing, got: #{context.html}"

        {:ok, context}
      end

      then_ "nothing belonging to a later stage is showing alongside it", context do
        refute has_element?(context.view, "[data-test='draft-story']"),
               "draft stories are showing at the same time as the plan card, got: " <>
                 "#{context.html}"

        refute has_element?(context.view, "[data-test='signup-card']"),
               "the sign-up card is showing at the same time as the plan card, got: " <>
                 "#{context.html}"

        {:ok, context}
      end
    end
  end
end
