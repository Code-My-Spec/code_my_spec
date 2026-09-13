defmodule CodeMySpecSpex.Story990.Criterion2230Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2230 — The plan names its guesses back, and every one of them can
  be corrected.

  Rule: nothing the shaper concludes is applied silently — it comes back as
  something on the plan card the visitor can read and change before anything
  is built.

  Two things are asserted: that the two generator conclusions (sign-in,
  separate copies) are rendered as editable controls rather than absorbed into
  prose, and that the summary itself names what was inferred instead of
  presenting a finished decision.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "Every inference the plan makes is stated, and stated as something to change" do
    scenario "The plan names its guesses back, and every one of them can be corrected" do
      given_ "a visitor who has described what they want to build", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they answer the shaping questions", context do
        html = answer_shaping_questions(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the plan they get back names what it concluded", context do
        assert context.html =~ "what I think you&#39;re building",
               "expected a plan stating its conclusions, got: #{context.html}"

        assert context.html =~ "These are my guesses",
               "expected the plan to say these are guesses, not settled facts, got: " <>
                 "#{context.html}"

        {:ok, context}
      end

      then_ "each of those inferences is presented as something the visitor can change",
            context do
        assert has_element?(context.view, "select[name='plan[needs_sign_in]']"),
               "expected sign-in to be an editable choice, not prose the visitor can only read"

        assert has_element?(context.view, "select[name='plan[separate_copies]']"),
               "expected separate-copies to be an editable choice, not prose the visitor " <>
                 "can only read"

        assert has_element?(context.view, "input[name='plan[account_name]']"),
               "expected the account name to be an editable field"

        assert has_element?(context.view, "input[name='plan[project_name]']"),
               "expected the project name to be an editable field"

        {:ok, context}
      end

      then_ "what they leave or correct is what moves forward", context do
        result =
          context.view
          |> form("form[phx-submit=confirm_names]", %{
            plan: %{
              account_name: "Acme",
              project_name: "Salon Book",
              needs_sign_in: "false",
              separate_copies: "false",
              location: "local"
            }
          })
          |> render_submit()

        # Anonymous, so "moves forward" is the sign-up card appearing in the
        # same conversation (990/3398) — not a redirect, which is what an
        # anonymous visitor confirming a plan used to get and no longer does.
        assert is_binary(result),
               "expected a correction to the plan's own booleans to be accepted and move " <>
                 "the visitor on, not be refused. Got: #{inspect(result)}"

        assert has_element?(context.view, "[data-test='signup-card']"),
               "expected the correction to be accepted and the visitor moved on to the " <>
                 "sign-up card, got: #{result}"

        {:ok, context}
      end
    end
  end
end
