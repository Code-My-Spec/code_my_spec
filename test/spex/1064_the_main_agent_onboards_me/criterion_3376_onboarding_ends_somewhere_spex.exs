defmodule CodeMySpecSpex.Story1064.Criterion3376Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3376 — Confirming the plan produces a project and puts the person in
  front of the agent that runs it.

  ## "Ends somewhere" is the whole criterion

  Onboarding that finishes by returning the visitor to where they started, or to
  a page telling them what to do next, has not ended — it has stopped. The two
  `then_`s are the two halves of having arrived: something exists, and they are
  looking at the thing that will work on it.

  ## Why this visitor is signed in

  Confirming sends an anonymous visitor to `/users/register`. That is the right
  behaviour and it is criterion 3369's subject, but it makes a poor setting for
  this one: a scenario that confirmed anonymously and then asserted "there is a
  project" would be satisfied by a signup form, which is the exact vacuous pass
  this criterion exists to rule out. Somebody has to be signed in for there to
  be an end to arrive at.

  ## Where the assertions are made

  `confirm_plan/2` returns the path the confirmation navigated to rather than
  the rendered page, and it does that on purpose — "so a spec can assert on
  where the visitor ended up rather than assuming it". A spec that only
  re-mounted and looked around would pass for a page rendering the same markup
  at a different address.

  Both halves are then read off that destination rather than out of the
  database. `then_` may not go to the database, and it should not want to:
  "there is a project" is only true if the visitor can see one, and the
  workspace is where they see it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "the questions have been answered" do
    scenario "Onboarding ends somewhere" do
      given_ "the questions have been answered", context do
        # `live/2` discards the conn it built, so the intake token minted on the
        # way in would be minted again on the next call and the plan confirmed
        # here would belong to nobody. Holding the conn keeps this one visitor.
        conn = get(context.conn, "/build")
        {:ok, live, _html} = live(conn)

        describe_idea(live, "a booking tool for a two-chair barbershop")
        answer_shaping_questions(live)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "onboarding finishes", context do
        destination = confirm_plan(context.live, %{location: "local"})

        {:ok, Map.put(context, :destination, destination)}
      end

      then_ "there is a project", context do
        assert is_binary(context.destination),
               """
               Confirming the plan did not take the visitor anywhere. Onboarding
               that ends by leaving somebody on the form they just submitted has
               not finished, it has stopped.
               """

        refute context.destination == "/build",
               "confirming returned the visitor to the intake they had just completed"

        {:ok, live, _html} = live(context.conn, context.destination)

        assert has_element?(live, "[data-test='local-instructions']"),
               """
               The visitor arrived somewhere with nothing of theirs on it. What
               makes this an ending rather than a stop is that a project exists
               and they can see it — here, the commands that bring up the one
               just created for them.
               """

        {:ok, Map.put(context, :live, live)}
      end

      and_ "they are in front of the agent that runs it", context do
        assert has_element?(context.live, "[data-test='intake-transcript']"),
               """
               The conversation did not come with them. Signup sits between the
               two pages and a LiveView cannot survive that navigation, so
               continuity here has to be rebuilt rather than kept — and when the
               rebuilding is skipped the visitor arrives at a page that looks
               like a different product.
               """

        assert has_element?(context.live, "form[phx-submit=answer]"),
               """
               The agent is not asking anything. A transcript the person can read
               but not reply to is a record of onboarding, not the agent that
               takes it on from here.
               """

        {:ok, context}
      end
    end
  end
end
