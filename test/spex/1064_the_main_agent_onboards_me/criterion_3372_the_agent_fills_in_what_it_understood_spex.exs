defmodule CodeMySpecSpex.Story1064.Criterion3372Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3372 — The form shows what the agent understood, and the visitor can
  still change any of it.

  ## Two halves that pull against each other

  Showing what it understood is what makes the agent useful. Every field
  remaining editable is what stops that being a trap — the plan card's own copy
  says "These are my guesses — change anything that's wrong. What you confirm
  here is what gets built", and a guess the visitor cannot correct is a decision
  nobody made.

  So the second `then_` asserts the *absence* of `disabled` and `readonly` on the
  inputs rather than asserting they look editable. A field can be filled,
  visible, and still refuse to change.

  ## Why the assertion is against filled values, not against specific text

  What the agent understood comes from the shaper, and `Shaper.Scripted` decides
  it in test. Asserting a particular account name would be asserting the
  fixture's script rather than the criterion, and would go red the day somebody
  changes the script for an unrelated reason. What the criterion claims is that
  the fields carry the agent's conclusions rather than being left blank for the
  visitor to fill, so that is what this checks.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "somebody has described what they are building" do
    scenario "The agent fills in what it understood" do
      given_ "somebody has described what they are building", context do
        conn = Phoenix.ConnTest.build_conn()
        {:ok, live, _html} = live(conn, "/build")

        describe_idea(live, "a booking tool for a two-chair barbershop")

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "the agent has understood it", context do
        html = answer_shaping_questions(context.live)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the form shows what it understood", context do
        assert has_element?(context.live, "[data-test='intake-plan']"),
               "the agent never produced a plan, so there is nothing to have understood"

        for field <- ~w(account_name project_name) do
          assert has_element?(
                   context.live,
                   "[data-test='intake-plan'] input[name='plan[#{field}]']"
                 ),
                 "the plan card has no #{field} field for the agent to have filled"

          refute context.html =~ ~r/name="plan\[#{field}\]"[^>]*value=""/,
                 """
                 `#{field}` is on the form and empty. The agent describing what it
                 understood and then handing over a blank field is the same as not
                 having understood it — the visitor is left doing the work either
                 way.
                 """
        end

        {:ok, context}
      end

      and_ "every field it filled can still be edited", context do
        refute context.html =~ ~r/<input[^>]*name="plan\[[^"]*\][^>]*\bdisabled\b/,
               "a field the agent filled is disabled, so its guess cannot be corrected"

        refute context.html =~ ~r/<input[^>]*name="plan\[[^"]*\][^>]*\breadonly\b/,
               """
               A field the agent filled is read-only. The card's own copy promises
               "change anything that's wrong", and a guess the visitor cannot
               correct is a decision nobody made.
               """

        {:ok, context}
      end
    end
  end
end
