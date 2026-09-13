defmodule CodeMySpecSpex.Story990.Criterion3402Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3402 — An anonymous visitor describes an idea and gets a plan
  back.

  Rule: a visitor gets a plan for what they described, and what to build
  first, without signing in.

  Close kin of 990/8209, which proves the same visitor is never asked for an
  email or a password before the plan appears. What this one adds is the
  other half of the plan: not only a summary of what they are building, but
  the first thing worth building — the sentence that turns "here's what I
  think you want" into something they could actually start on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @description "a booking tool for hair salons, so owners can see their week"

  spex "A visitor gets a plan for what they described, and what to build first" do
    scenario "An anonymous visitor describes an idea and gets a plan back" do
      given_ "a visitor who has never signed in", context do
        {:ok, Map.put(context, :conn, build_conn())}
      end

      when_ "they describe what they want to build in their own words", context do
        {:ok, view, _html} = live(context.conn, "/build")

        describe_idea(view, @description)
        html = answer_shaping_questions(view)

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "they are shown a plan describing what they are building and the first thing to build",
            context do
        assert context.html =~ "what I think you&#39;re building",
               "expected a plan back, got: #{context.html}"

        assert has_element?(context.view, "[data-test='intake-plan']"),
               "expected the plan card to be shown, got: #{context.html}"

        # `Planner.Inferred`'s deterministic wording for this description — the
        # test double this suite runs against (config/test.exs). Not asserting
        # the summary alone: the plan card renders `summary` and `first_build`
        # as two separate paragraphs, and this is the one that names what to
        # build first.
        assert context.html =~ "The first thing to build is the one screen",
               "expected the plan to name what to build first, not only a summary of the " <>
                 "idea, got: #{context.html}"

        {:ok, context}
      end

      then_ "they were never asked to sign in or provide an email", context do
        refute context.html =~ ~r/password/i,
               "expected no password field before the gate, got: #{context.html}"

        refute context.html =~ ~r/type="email"/,
               "expected no email field before the gate, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
