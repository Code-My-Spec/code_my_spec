defmodule CodeMySpecSpex.Story990.Criterion8211Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8211 — The plan names its own guesses back to the visitor.

  Rule: the plan states every inference it made rather than applying it
  silently.

  A silently wrong guess costs the session — the visitor finds out after the
  build, by which point the thing they were shown is not the thing they
  wanted. Stating the inference and waiting for confirmation is the product's
  own AskUserQuestion pattern, applied at the moment it is cheapest to
  correct.

  Surface: the `/build` LiveView, driven anonymously.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "The plan states every inference rather than applying it silently" do
    scenario "The plan names its own guesses back to the visitor" do
      # Answered one at a time, because that is how they are asked. Submitting
      # the three at once was this spec agreeing with a form that should never
      # have existed.
      given_ "a visitor who has answered the shaping questions", context do
        {:ok, view, _html} = live(build_conn(), "/build")

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        html = answer_shaping_questions(view, ["yes", "no", "salon owners"])

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "it states what it concluded about sign-in and separate copies", context do
        assert context.html =~ "People sign in to use it.",
               "expected the sign-in inference stated back, got: #{context.html}"

        assert context.html =~ "Everyone shares the one set of data.",
               "expected the tenancy inference stated back, got: #{context.html}"

        {:ok, context}
      end

      then_ "it states the account and project names it proposes", context do
        assert context.html =~ "Account name"
        assert context.html =~ "Project name"

        {:ok, context}
      end

      then_ "every one of them is presented as something to confirm", context do
        assert has_element?(context.view, "input[name='plan[account_name]']"),
               "expected the proposed account name to be editable, not merely displayed"

        assert has_element?(context.view, "input[name='plan[project_name]']"),
               "expected the proposed project name to be editable, not merely displayed"

        {:ok, context}
      end

      # The half that was missing. The names were always editable; what the
      # plan concluded about sign-in and separate copies was prose the visitor
      # could only read — and those two decide which generators run, so they
      # are the inferences most worth being wrong about.
      then_ "the conclusions that pick the generators can be corrected too", context do
        assert has_element?(context.view, "[name='plan[needs_sign_in]']"),
               "expected the sign-in conclusion to be correctable, not stated as prose"

        assert has_element?(context.view, "[name='plan[separate_copies]']"),
               "expected the separate-copies conclusion to be correctable, not stated as prose"

        {:ok, context}
      end
    end
  end
end
