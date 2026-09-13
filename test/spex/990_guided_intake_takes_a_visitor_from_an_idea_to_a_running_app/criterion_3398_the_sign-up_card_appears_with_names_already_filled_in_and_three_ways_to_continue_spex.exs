defmodule CodeMySpecSpex.Story990.Criterion3398Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3398 — The sign-up card appears with names already filled in and
  three ways to continue.

  Rule: the gate is a card in the same conversation, not a different page.

  `gate_for/1` sends an anonymous visitor to `/users/register` today — a full
  navigation, which ends the LiveView the whole conversation has been living
  in and lands them on a page that knows nothing about what they just
  confirmed. This criterion is the replacement: the card that asks for an
  identity appears in the conversation the visitor is already having, already
  holding the names they just confirmed, with GitHub, Google and email offered
  together the way `UserLive.Registration`'s own card already offers them —
  just not stranded on a page transition that throws the conversation away.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "The card that asks for an identity is the same conversation, not a new page" do
    scenario "The sign-up card appears with names already filled in and three ways to continue" do
      given_ "a visitor who has confirmed their plan", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "the sign-up card appears in the conversation", context do
        result =
          context.view
          |> form("form[phx-submit=confirm_names]", %{
            plan: %{account_name: "Acme Widgets", project_name: "Widget Tracker"}
          })
          |> render_submit()

        {:ok, Map.put(context, :result, result)}
      end

      then_ "nothing already said has to be retyped into the card", context do
        assert is_binary(context.result),
               "expected the sign-up card to appear in the same conversation the visitor " <>
                 "was already having, but they were sent elsewhere instead: " <>
                 "#{inspect(context.result)}"

        {:ok, Map.put(context, :html, context.result)}
      end

      then_ "the account name and project name are already filled in from what was confirmed",
            context do
        assert has_element?(context.view, "[data-test='signup-card'] input[value='Acme Widgets']"),
               "expected the confirmed account name to already be in the sign-up card, " <>
                 "got: #{context.html}"

        assert has_element?(context.view, "[data-test='signup-card'] input[value='Widget Tracker']"),
               "expected the confirmed project name to already be in the sign-up card, " <>
                 "got: #{context.html}"

        {:ok, context}
      end

      then_ "GitHub, Google, and email are offered together, not one at a time", context do
        # `^=` (starts-with), not an exact match: the real link carries a
        # `return_to` query param so OAuth lands back on the workspace
        # rather than the marketing app — a detail this criterion does not
        # care about, only that GitHub is genuinely offered.
        assert has_element?(
                 context.view,
                 "[data-test='signup-card'] a[href^='/auth/github/login']"
               ),
               "expected GitHub offered in the sign-up card, got: #{context.html}"

        assert has_element?(
                 context.view,
                 "[data-test='signup-card'] a[href^='/auth/google/login']"
               ),
               "expected Google offered alongside GitHub, not instead of it, got: " <>
                 "#{context.html}"

        assert has_element?(context.view, "[data-test='signup-card'] input[type='email']"),
               "expected email offered alongside GitHub and Google, not instead of them, " <>
                 "got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
