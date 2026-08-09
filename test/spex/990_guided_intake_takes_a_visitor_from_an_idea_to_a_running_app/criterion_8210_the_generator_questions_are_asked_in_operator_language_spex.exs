defmodule CodeMySpecSpex.Story990.Criterion8210Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8210 — The generator inputs are inferred, not asked.

  Rule: what the generators need is inferred from a short conversation, never
  asked of the visitor.

  Sign-in and separate copies decide which generators run. They are our
  questions, not the visitor's — someone with an idea for a booking tool has no
  view on tenancy and should not be made to have one. "A booking tool for hair
  salons, my clients book their own slots" already answers both.

  This spec has been wrong twice, in the same direction both times. It first
  asserted that both questions appeared together, which a page of dropdowns
  satisfied. It then asserted they appeared one at a time, which a paginated
  page of dropdowns satisfied. Neither noticed that asking at all was the
  defect: the visitor was answering the generator's questions either way.

  Surface: the `/build` LiveView, driven anonymously.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  # The two things that must never be put to the visitor.
  @our_questions [~r/sign in to use this/i, ~r/separate businesses each use their own copy/i]

  spex "The visitor is asked about their business, never about the generators" do
    scenario "The generator inputs are inferred, not asked" do
      given_ "a visitor who has described what they want to build", context do
        {:ok, view, _html} = live(build_conn(), "/build")

        html =
          view
          |> form("form[phx-submit=describe]", %{
            description: "a booking tool for hair salons, my clients book their own slots"
          })
          |> render_submit()

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "nothing put to them is one of the generator's questions", context do
        for question <- @our_questions do
          refute context.html =~ question,
                 "the visitor was asked #{inspect(question)} — that is ours to work out, " <>
                   "and someone with an idea has no view on it"
        end

        {:ok, context}
      end

      then_ "no question uses product jargon", context do
        for jargon <- [~r/multi-?tenan/i, ~r/authentication/i, ~r/\btenancy\b/i] do
          refute context.html =~ jargon,
                 "expected no product jargon in the conversation, found #{inspect(jargon)}"
        end

        {:ok, context}
      end

      when_ "they answer whatever was asked, in their own words", context do
        html = answer_shaping_questions(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the conversation ends and the plan is there", context do
        assert context.html =~ "what I think you&#39;re building",
               "expected the conversation to reach a plan within a couple of questions"

        {:ok, context}
      end

      then_ "both generator inputs were worked out without being asked", context do
        assert has_element?(context.view, "[name='plan[needs_sign_in]']"),
               "expected a conclusion about sign-in on the plan"

        assert has_element?(context.view, "[name='plan[separate_copies]']"),
               "expected a conclusion about separate copies on the plan"

        {:ok, context}
      end
    end
  end
end
